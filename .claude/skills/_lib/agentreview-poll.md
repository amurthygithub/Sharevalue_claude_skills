# Playbook: poll for the agent-review consensus comment

`/agentreview` posts a single structured PR comment whose body starts
with `## 🤖 Agent Consensus Review` and contains both the SHA reviewed
and the per-agent verdicts. Skills that act on that verdict (today:
`/ship`'s review-wait step) poll for the comment, **anchor on the
current HEAD short-SHA**, **filter to trusted comment authors**, and
parse the result into a verdict label + blocker count.

## Consumers

- `.claude/skills/ship/SKILL.md` — review-wait step (gates the
  auto-merge step that follows it).

Any future skill that consumes a review verdict reuses this same loop;
do not re-derive it.

## Why the SHA anchor matters

A long-lived PR accumulates multiple agent-review comments — one per
push that triggered the pre-push hook. "Find the latest comment whose
body starts with the header" picks up a verdict on a *previous* SHA
after the user re-pushes fixes. The poll MUST filter to comments whose
`**SHA reviewed:**` line matches the current head SHA.

**SHA width must match the producer exactly.** `/agentreview` stamps
the comment with the PR head oid truncated to a fixed width (e.g.
`gh pr view --json headRefOid | cut -c1-7` for 7 chars). A
`contains($sha)` filter therefore MUST anchor on the **same** width —
`git rev-parse HEAD | cut -c1-7`, NOT `git rev-parse --short HEAD`,
which yields the min-unambiguous length (often 8). An 8-char anchor
never substring-matches a 7-char comment SHA, so the poll silently
never matches and falls through to its timeout. Pick one width, use it
in both the producer and every consumer.

## Why the author filter matters

Anyone with `gh pr comment` access can post a comment that mimics the
agent-review structure. Without an author filter, a spoofed
`Verdict: ✅ APPROVED` comment would bypass the merge gate. The poll
filters to comments whose author login is in an explicit trusted-authors
set. Extend the set by appending space-separated logins.

```bash
# CUSTOMIZE: the gh login(s) under which your /agentreview orchestrator
# posts. Usually the developer's own login (the orchestrator runs the
# gh CLI) plus your review bot's login if you wire a formal approval.
TRUSTED_AUTHORS="<REVIEW_AUTHOR_LOGIN> <BOT_NAME>"
```

The formal GitHub App approval (a `gh pr review`, not a `gh pr comment`)
is a *separate* signal consumed via branch protection's required-approvals
gate — not by this poll loop.

## State machine

```
START
  │
  ▼
fetch last 20 PR comments via gh
  │
  ├── transient gh failure ──► sleep 15s ──► loop
  │
  ▼
filter: author IN trusted set
filter: body starts with "## 🤖 Agent Consensus Review"
filter: body contains current HEAD short-SHA
  │
  ├── no match yet ──► sleep 15s ──► loop (until deadline)
  │
  ▼
extract VERDICT       from line `**Verdict:** <emoji + label>`
extract BLOCKERS    = count of `- [SEVERITY: blocker]` lines
extract COMMENT_URL = the matched comment's URL
extract COMMENT_BODY = full markdown body of the matched comment
  │
  ▼
return (VERDICT, BLOCKERS, COMMENT_URL, COMMENT_BODY)
```

`COMMENT_BODY` is the unparsed markdown of the matched comment.
Consumers needing only the verdict + blocker count can ignore it;
consumers that parse findings out of the per-lens `<details>` blocks
need it. It is already in hand from the same `gh pr view --json comments`
fetch — no extra round-trip.

Verdicts the consumer must handle:

| Verdict literal | Consumer action |
|---|---|
| `✅ APPROVED` | Eligible to proceed (subject to `BLOCKERS == 0` and any consumer gates) |
| `✅ APPROVED WITH NOTES` | Same as APPROVED |
| `⚠️ APPROVED-WITH-DISSENT` | Halt — at least one reviewer requested changes |
| `❌ NEEDS CHANGES` | Halt — surface verdict + findings to user |
| `🟦 SKIPPED (docs-only)` | Halt — review intentionally not run (prose-only diff, no danger-zone path). Require explicit human merge; do NOT auto-merge on SKIPPED. |
| empty (timeout) | Halt — surface `Agent review didn't post in <N> min` + the comment-log path |

`🟦 SKIPPED` comes from a docs-only short-circuit in `/agentreview`
that only fires when **every** changed path is prose-only AND no path
matches the danger-zone regex (`.claude/skills/_lib/danger-zone-scan.md`).
Treat it as halt-for-human: a prose-only PR still needs human eyes for
content (factual accuracy, link integrity, tone) — the lenses just have
low signal on it.

## Anchoring details

- **Time budget**: a few minutes (e.g. 300s). The orchestrator typically
  finishes in well under 90s; the cushion absorbs sub-agent variance and
  transient `gh` failures.
- **Comment slice**: last 20 comments only. Long-lived PRs accumulate
  noise; the agent-review comment is always the most recent of its kind
  among trusted authors, so the slice is safe and keeps `jq` fast.
- **Verdict extraction**: anchor on the `**Verdict:** ` line prefix.
  Per-agent table rows contain the same emojis and would shadow the
  canonical verdict if matched globally.
- **Blocker count**: count lines beginning with `- [SEVERITY: blocker]`.
  Counting the section heading instead returns 0 or 1, which lies when
  there are multiple blockers.
- **pipefail scope**: wrap the `gh ... | jq ...` pipeline in a subshell
  with `set -o pipefail` so a transient `gh` 401/404 trips the `||`
  branch (continue the loop). Do NOT leak `pipefail` into the rest of
  the consumer's bash — it breaks legitimate grep-pipelines that exit 1
  on no-match.

## Reference implementation (skeleton)

```bash
HEAD_SHORT=$(git rev-parse HEAD | cut -c1-7)
DEADLINE=$(( $(date +%s) + 300 ))
VERDICT=""; BLOCKERS=0; COMMENT_URL=""; COMMENT_BODY=""

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  COMMENT=$(
    set -o pipefail
    gh pr view "$PR" --json comments -q "
      .comments[-20:] | reverse
      | map(select(.author.login as \$a | \"$TRUSTED_AUTHORS\" | split(\" \") | index(\$a)))
      | map(select(.body | startswith(\"## 🤖 Agent Consensus Review\")))
      | map(select(.body | contains(\"$HEAD_SHORT\")))
      | .[0]" 2>/dev/null
  ) || { sleep 15; continue; }   # transient gh failure → retry

  if [ -n "$COMMENT" ] && [ "$COMMENT" != "null" ]; then
    COMMENT_BODY=$(jq -r '.body' <<<"$COMMENT")
    COMMENT_URL=$(jq -r '.url'  <<<"$COMMENT")
    VERDICT=$(grep -E '^\*\*Verdict:\*\*' <<<"$COMMENT_BODY" \
      | grep -oE '✅ APPROVED( WITH NOTES)?|⚠️ APPROVED-WITH-DISSENT|❌ NEEDS CHANGES|🟦 SKIPPED' \
      | head -1)
    BLOCKERS=$(grep -cE '^- \[SEVERITY: blocker\]' <<<"$COMMENT_BODY" | tr -d ' ')
    break
  fi
  sleep 15
done
# VERDICT empty here == timeout → halt and surface to the user.
```

## Anti-patterns

- **Don't match by recency alone.** A long-lived PR has many old
  agent-review comments; filter on the current HEAD SHA so the verdict
  is fresh.
- **Don't trust the verdict alone for danger-zone paths.** Pair this
  poll with the danger-zone scan (`.claude/skills/_lib/danger-zone-scan.md`)
  so a prompt-injected APPROVE cannot smuggle a `.claude/skills/` edit
  into staging. Two independent gates.
- **Don't auto-retry on a malformed comment.** If `jq` returns the
  comment but verdict extraction fails, the orchestrator hit an error
  and the user needs to see the raw body. Surface and halt.

## Consumer expectation: first APPROVED ships

The verdict's job is to gate the merge — not to invite another round of
fixes. Consumers MUST encode the following or they fall into the
nit-iteration trap (an earlier iteration of these skills saw a PR take
4 rounds before round 1 was finally treated as terminal):

- **First APPROVED + 0 blockers = merge.** Non-blocker findings
  (severity `minor` / `nit`) never gate the merge, regardless of count.
- **Each fresh push triggers a new /agentreview round, surfacing new
  nits.** Past round 3 the loop saturates: only the occasional even
  round catches a real bug; the rest surface only nits that each fix
  commit unlocks. The cost-benefit collapses fast.
- **Persist a per-PR round counter.** Consumers that allow iteration
  (e.g. `/ship`) MUST hard-cap rounds at 3 and persist the count
  somewhere stable across invocations. `$GIT_COMMON_DIR/.<consumer>-pr<N>.rounds`
  is the convention — `$GIT_COMMON_DIR` survives worktrees and ephemeral
  state.
- **The user-facing prompt at the merge gate MUST offer exactly two
  outcomes**: merge, or stop. Offering "address findings" as an
  in-consumer alternative is the load-bearing failure mode — it makes
  the merge gate look like a triage menu, which is how the nit-iteration
  loop takes root. If the user wants to fix something, they push outside
  the consumer.
- **If fixes are genuinely needed, sweep ALL findings in ONE commit.**
  Splitting across commits means each commit triggers a fresh review
  that surfaces fresh nits. One commit per round, all-or-nothing.

These behaviors live in `.claude/skills/ship/SKILL.md`'s review-wait and
merge steps. Future consumers inherit the rule by reference.

## Spawning conventions

Two spawn paths produce the agent-review process; both write the same
files so the watcher pattern below is single-path:

| Path | Spawn shape | Files written |
|---|---|---|
| Pre-push git hook (`scripts/ci-local.sh`) | `nohup … & disown` — the hook must exit immediately so `git push` returns. **The ONE legitimate detached spawn.** | `$GIT_COMMON_DIR/.agent-review-pr<N>.log` (orchestrator stdout) + `.agent-review-pr<N>.pid` |
| `/ship` first-push branch (PR didn't exist at push time) | Same `nohup … & disown` shape so the orchestrator survives `/ship`'s subshell. "In-session" refers only to the Claude session being alive — the spawned process must still be detached. | Same files |

Both paths produce the same on-disk contract, so consumers don't need to
know who spawned.

### The watcher: `scripts/agentreview-watch.sh`

Invoke via the `Monitor` tool to convert the detached spawn's
otherwise-silent runtime into a visible stream of notifications — each
line of the watcher's stdout becomes a chat notification. Per the
"silence is not success" rule, the watcher emits on **every** terminal
state, not just the happy path:

| Line prefix | Meaning | Exit |
|---|---|---|
| `[start]` | Watcher attached; records pid + log path. | (continues) |
| `[heartbeat]` | Periodic liveness check (default ~180s, env-overridable). | (continues) |
| `[verdict]` | Orchestrator finished. Detected via the log fast-path OR — when stdout is unmatchable — via this same SHA-anchored, trusted-author comment poll. | 0 |
| `[skipped]` | Docs-only short-circuit. Terminal success; consumer halts the auto-merge per the SKIPPED row above. | 0 |
| `[stall]` | Log idle past the stall threshold (default ~600s). Process alive but not progressing. | 1 |
| `[failure]` | pid file points at a dead process AND no verdict landed. Last log line included for context. | 1 |
| `[timeout]` | Watcher hit its own MAX_WAIT. | 1 |

The watcher also appends a `RUN_LOG` line on each state transition
(`start | verdict | skipped | stall | failure | timeout`) so
post-incident timelines exist.

### Consumer integration

The watcher is the "stay informed" signal; the comment-poll state
machine above is the merge-gate signal. Complementary, not redundant:

1. Spawn or inherit the agent-review process (either path above).
2. Invoke `Monitor` with `scripts/agentreview-watch.sh $PR`, `timeout_ms`
   ≥ the watcher's MAX_WAIT, `persistent: false`. Heartbeats flow as
   notifications without blocking the orchestrator.
3. On `[verdict]` or `[skipped]`, enter the comment-poll state machine
   above. The comment is already posted by then, so the poll typically
   returns on its first iteration.
4. On `[stall]` / `[failure]` / `[timeout]`, halt and surface the line
   — these are halt-for-human states, not retry targets.

### Anti-patterns for spawn/wait

- **Don't poll for completion without a watcher.** A tight `sleep 15`
  loop inside the consumer's bash burns context and gives the user zero
  visibility during the wait — the friction this section exists to fix.
- **Don't use `Bash run_in_background` for a watcher.** It gives ONE
  notification (on exit). The point is per-line streaming for the
  heartbeat — that requires `Monitor`.
- **Don't reach for `nohup … & disown` outside the two paths above.**
  Those are the only legitimate detached spawns; everywhere else prefer
  `Monitor` or `Bash run_in_background`.
