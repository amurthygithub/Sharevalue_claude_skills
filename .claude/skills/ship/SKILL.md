---
name: ship
description: Ship the current feature branch to <STAGING_BRANCH> — commit any uncommitted changes, push (triggers pre-push hook + agent review), open PR if missing, wait for consensus, merge to <STAGING_BRANCH> unless blockers or danger-zone hits.
argument-hint: "[--no-merge] [--draft]"
allowed-tools: Bash, Read, Write
user-invocable: true
disable-model-invocation: false
---

You are shipping the current feature branch to `<STAGING_BRANCH>`. Be **autonomous on the happy path**, **halt and surface** on anything risky.

Hard rules:
- **NEVER** push to `<DEFAULT_BRANCH>` / `<STAGING_BRANCH>` directly. PRs only.
- **NEVER** merge a PR into `<DEFAULT_BRANCH>`. `/promote` is the only path to prod and is user-invoked.
- **NEVER** bypass the pre-push hook (`--no-verify`, `CI_BYPASS=1`, `SKIP_AGENT_REVIEW=1`).
- **NEVER** force-push.

These four prohibitions are absolute. If a gate is genuinely broken, that is a
separate ticket — it is never a `/ship` escape hatch.

## Flags

```bash
NO_MERGE_FLAG=0
DRAFT_FLAG=0
echo "$ARGUMENTS" | grep -q -- '--no-merge' && NO_MERGE_FLAG=1
echo "$ARGUMENTS" | grep -q -- '--draft'    && DRAFT_FLAG=1
```

## Step 1 — Validate

```bash
test -n "$<TRACKER>_API_KEY" || { echo "❌ <TRACKER>_API_KEY not set"; exit 1; }
command -v gh >/dev/null   || { echo "❌ gh CLI not found"; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "❌ not in a git repo"; exit 1; }

BRANCH=$(git rev-parse --abbrev-ref HEAD)
case "$BRANCH" in
  <DEFAULT_BRANCH>|<STAGING_BRANCH>|HEAD)
    echo "❌ /ship from a protected branch is forbidden. Run /work-on first."
    exit 1
    ;;
esac
git fetch origin --quiet
```

## Step 1.5 — Verify the branch lock (push interlock)

If your repo runs parallel agent sessions, a per-branch lock prevents two
sessions from landing commits on the same PR. The push is the **one place
the lock is load-bearing** — coding-time conflicts are advisory, but a
push-time conflict lands your commits on someone else's branch. Refuse to
ship if another live session owns this branch.

```bash
# CUSTOMIZE: point at your branch-lock helper, or delete this Step if you
# don't run parallel sessions. The helper should `verify <branch>` with
# exit 0 = you own it (or it's free), non-zero = someone else owns it.
BRANCH_LOCK="$(git rev-parse --show-toplevel)/scripts/branch-lock.sh"
if [ -x "$BRANCH_LOCK" ] && ! "$BRANCH_LOCK" verify "$BRANCH"; then
  echo "🛑 Branch '$BRANCH' is locked by another live session."
  echo "   Refusing to push — commits would land on the wrong PR."
  echo "   Coordinate (have them /ship first) or force a takeover if it's dead."
  exit 1
fi
```

## Step 2 — Determine the ticket

Priority order:

1. `.claude/active-ticket.md` — top line `# Active ticket: <TRACKER_TEAM_KEY>-NNN — <title>`.
2. Branch name pattern `<prefix>/<ticket-id-lowercased>-...` — derive ticket id (uppercased).
3. Last commit's `Refs: <TRACKER_TEAM_KEY>-NNN` footer.

If none resolves a ticket, abort. Capture `TICKET_ID`, `TICKET_TITLE`, `TICKET_URL`.

## Step 3 — Detect danger-zone touches BEFORE committing (advisory gate)

This is **gate one of two**. Source the canonical regex + scan helpers from
a single shared script — do NOT inline the regex here. Keeping the danger-path
definition in exactly one place is what lets `CLAUDE.md` §9.2, this Step, and
the bypass-resistant Step 8 re-scan all agree.

```bash
# CUSTOMIZE: this helper is the single source of truth for the danger-path
# regex + the scan functions. Keep it in sync with CLAUDE.md §9.2.
. "$(git rev-parse --show-toplevel)/scripts/danger-zone-scan.sh"

# Scan the union of staged + unstaged + already-pushed
# (origin/<STAGING_BRANCH>..HEAD). The helper returns non-zero if
# origin/<STAGING_BRANCH> is unreachable — fail CLOSED (halt), never
# fail open silently. A gate that can't run must not pretend it passed.
danger_zone_scan_full > /tmp/ship-danger.txt || {
  echo "🛑 Cannot verify danger-zone scan — origin/<STAGING_BRANCH> unreachable."
  echo "   Run \`git fetch origin <STAGING_BRANCH>\` then retry /ship."
  exit 1
}

if [ -s /tmp/ship-danger.txt ]; then
  echo "🛑 Danger-zone files in this change set:"
  sed 's/^/  - /' /tmp/ship-danger.txt
  echo "These require manual review per CLAUDE.md §9. /ship will commit + push + run review,"
  echo "but will NOT auto-merge."
  DANGER_ZONE_HIT=1
fi
```

`DANGER_ZONE_HIT` is consulted at the merge gate. This Step is advisory —
commit + push + review still proceed; only the *merge* is blocked.

## Step 4 — Stage and commit any uncommitted changes

If working tree is clean, skip.

```bash
git add -A
# Belt-and-suspenders unstage of obvious secrets the user may have left in.
git reset HEAD -- '*.env' '.env*' '*.key' '*.pem' '*credentials*' 2>/dev/null || true
```

Build the commit message:

- Subject: pick a Conventional Commits prefix (`feat|fix|chore|refactor|docs|perf|test|ci|build`) from `<branch-prefix>`, else infer from `TICKET_TITLE`. Default: `chore`.
- Scope: pick from CLAUDE.md §3 allowed list (`<COMMIT_SCOPES>`). Omit if unsure.
- Subject body: `<TICKET_TITLE>` truncated to 72 chars.

Footer (always):

```
Refs: <TICKET_ID>

Co-Authored-By: <agent-coauthor>
```

If the commit-msg hook rejects it, fix and retry once. If still failing, surface the error and exit 1 — do NOT use `--no-verify`.

## Step 5 — Push

```bash
git push -u origin "$BRANCH"
```

The pre-push hook will:

1. Run `ci-local.sh --quick`. Non-zero → push aborted; surface the failing output.
2. If a PR exists for this branch, fire `/agentreview` in the background through
   a wrapper that **scrubs the environment** before exec — dropping every var
   not on a tight allowlist so the reviewer can't read your shell secrets (any
   `*_SECRET` / `*_TOKEN` / `*_API_KEY` / `*_PASSWORD` the shell exports). The
   reviewer keeps only what it needs: the `gh` auth token, its own model API
   key, and the `<TRACKER>` key.

If push fails for any reason, surface the error and exit 1.

## Step 6 — Open the PR if it doesn't exist + handle the first-push race

The pre-push hook only fires `/agentreview` when a PR already exists. On the
**first** `/ship` for a new branch, the push happens before the PR — so we
explicitly fire the review after opening the PR.

```bash
NEWLY_OPENED=0
PR=$(gh pr view "$BRANCH" --json number -q .number 2>/dev/null || echo "")

# Early-exit if the PR is already merged — a second /ship would push a no-op
# and poll forever for a review that never comes. Saves the full poll window.
if [ -n "$PR" ]; then
  PR_STATE=$(gh pr view "$PR" --json state -q .state 2>/dev/null)
  if [ "$PR_STATE" = "MERGED" ]; then
    echo "✅ PR #$PR is already MERGED. Nothing to ship."
    exit 0
  fi
fi

if [ -z "$PR" ]; then
  NEWLY_OPENED=1
  DRAFT_FLAG_ARG=""
  [ "$DRAFT_FLAG" = "1" ] && DRAFT_FLAG_ARG="--draft"
  gh pr create \
    --base <STAGING_BRANCH> \
    --head "$BRANCH" \
    --title "<commit-subject>" \
    $DRAFT_FLAG_ARG \
    --body "$(cat <<EOF
## Summary
<one-paragraph from ticket description, truncated to 400 chars>

## <TRACKER> ticket
[$TICKET_ID]($TICKET_URL) — $TICKET_TITLE

## Test plan
- [ ] CI green
- [ ] (manual) feature working as described in ticket

🤖 Auto-opened by \`/ship\` — agent review will run automatically.
EOF
)"
  PR=$(gh pr view "$BRANCH" --json number -q .number)
fi

# Just-opened PRs missed the hook's review trigger. Spawn it explicitly,
# mirroring the hook's wiring: a per-PR lock + kill-existing-PID debounce so
# re-running /ship doesn't stack two reviews on the same SHA. Use the SHARED
# .git common-dir (not $REPO_ROOT/.git) so this works from a worktree, where
# $REPO_ROOT/.git is a file, not a directory.
if [ "$NEWLY_OPENED" = "1" ]; then
  GIT_COMMON_DIR=$(git rev-parse --git-common-dir)
  case "$GIT_COMMON_DIR" in /*) ;; *) GIT_COMMON_DIR="$(git rev-parse --show-toplevel)/$GIT_COMMON_DIR" ;; esac
  LOG="$GIT_COMMON_DIR/.agent-review-pr${PR}.log"
  LOCK="$GIT_COMMON_DIR/.agent-review-pr${PR}.pid"
  if [ -f "$LOCK" ]; then
    OLD_PID="$(cat "$LOCK" 2>/dev/null)"
    case "$OLD_PID" in ''|*[!0-9]*) OLD_PID="" ;; esac
    [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null && kill "$OLD_PID" 2>/dev/null || true
  fi
  # CUSTOMIZE: point at your env-scrubbing review-spawn wrapper. `env -u
  # BASH_ENV -u ENV` closes the startup-injection window BEFORE bash starts
  # the wrapper; `</dev/null` + nohup + disown detach so this shell isn't
  # held open on the background review's fd table.
  MAIN_ROOT=$(cd "$(dirname "$GIT_COMMON_DIR")" && pwd)
  ( cd "$MAIN_ROOT" && nohup env -u BASH_ENV -u ENV \
      "$MAIN_ROOT/scripts/agentreview-spawn.sh" "$PR" \
      </dev/null >"$LOG" 2>&1 ) &
  echo "$!" > "$LOCK"
  disown 2>/dev/null || true
fi
```

For subsequent `/ship` runs (PR already exists), the pre-push hook handles the
review trigger. Same detached shape. Optionally attach a heartbeat watcher
(`Monitor` against a watch script) so you get periodic status without re-typing
`check` — the watcher must emit on every terminal state (verdict / stall /
failure / timeout), not just the happy path.

## Step 7 — Wait for agent-review consensus

Poll up to 5 minutes (timeout = halt for user). Match the **latest** comment
that (a) starts with `## 🤖 Agent Consensus Review`, (b) stamps the current
`HEAD` short SHA, AND (c) is authored by a **trusted author**. All three
conditions are load-bearing:

- **SHA anchor** ties the verdict to the exact commit under review, so a stale
  APPROVE from an earlier push can't gate a newer one. Match the orchestrator's
  stamp width exactly (it writes a 7-char SHA; an 8-char `contains()` anchor
  never substring-matches → silent timeout).
- **Trusted-author filter** is the anti-spoof gate. The comment is posted from
  the orchestrator's authenticated `gh` shell, so only that identity can
  produce one `/ship` will trust. Without this filter, ANY PR commenter could
  paste a fake `APPROVED` body and walk the merge gate open.

```bash
HEAD_SHORT=$(git rev-parse HEAD | cut -c1-7)   # MUST match the orchestrator's stamp width
DEADLINE=$(($(date +%s) + 300))
VERDICT=""; BLOCKERS=0; COMMENT_URL=""

# CUSTOMIZE: the gh login(s) the orchestrator posts under. Space-separated.
AGENTREVIEW_TRUSTED_AUTHORS='<BOT_NAME>'

while [ $(date +%s) -lt $DEADLINE ]; do
  # pipefail scoped to the subshell so a transient gh 401/404 trips the `||`
  # (retry) instead of feeding empty stdout to jq → silent timeout.
  COMMENT=$(set -o pipefail; gh pr view "$PR" --json comments \
    | jq --arg authors "$AGENTREVIEW_TRUSTED_AUTHORS" --arg sha "$HEAD_SHORT" '
        .comments[-20:] | reverse
        | map(select(.author.login | IN($authors | split(" ") | .[])))
        | map(select(.body | startswith("## 🤖 Agent Consensus Review")))
        | map(select(.body | contains($sha)))
        | .[0]
      ') || { sleep 15; continue; }
  if [ "$COMMENT" != "null" ] && [ -n "$COMMENT" ]; then
    BODY=$(jq -r '.body' <<<"$COMMENT")
    # Anchor verdict to the **Verdict:** line so per-agent rows carrying the
    # same emojis don't shadow the canonical verdict.
    VERDICT=$(grep -E '^\*\*Verdict:\*\*' <<<"$BODY" \
              | grep -oE '✅ APPROVED( WITH NOTES)?|⚠️ APPROVED-WITH-DISSENT|❌ NEEDS CHANGES|🟦 SKIPPED \(docs-only\)' \
              | head -1)
    # Count blocker BULLETS, not the section heading (heading → 0/1, lies on >1).
    BLOCKERS=$(grep -cE '^- \[SEVERITY: blocker\]' <<<"$BODY" | tr -d ' ')
    break
  fi
  sleep 15
done
```

**Consensus math** (computed by `/agentreview`; `/ship` only reads the verdict):
the reviewer runs N independent lenses and ships on a **majority APPROVE** (the
template default is a 3-agent panel where 2-of-3 APPROVE ships; scale N to your
risk appetite but keep it odd so there's no tie). One dissenting
`REQUEST_CHANGES` downgrades to `⚠️ APPROVED-WITH-DISSENT`; ≤ a minority
approving is `❌ NEEDS CHANGES`.

| Outcome | Action |
|---|---|
| `VERDICT` empty (timeout) | `⏱ Agent review didn't post in 5 min. Check $LOG and re-run /ship.` Exit 1. |
| `❌ NEEDS CHANGES` | Print verdict + comment URL + findings. Exit 1, no merge. |
| `⚠️ APPROVED-WITH-DISSENT` | Print verdict + dissent. Halt for user — do NOT merge. |
| `🟦 SKIPPED (docs-only)` | Halt for user — prose still needs human eyes. Do NOT merge. |
| `✅ APPROVED(_WITH_NOTES)` and `BLOCKERS == 0` | Proceed to Step 8. |
| `BLOCKERS > 0` (any verdict) | Halt regardless. Print blockers. |

**Iteration cap.** Persist a per-PR round counter (e.g. under the shared
`.git` common-dir). Each fresh push triggers a fresh review that surfaces
*new* nits indefinitely — past ~3 rounds the loop saturates (rounds 2 and 4
occasionally catch a real bug; the rest are nits). Cap at 3 and stop iterating.

## Step 8 — Surface merge gate (explicit user confirmation)

The merge is **always explicit**. /ship does NOT auto-merge even on a clean
APPROVED + 0 blockers — each merge is a per-action, present-tense decision.
Earlier iterations auto-merged; that path repeatedly degenerated into a
nit-iteration loop because the post-verdict prompt was treated as "address
findings first," which triggered a fresh review round, which surfaced fresh
nits, forever. The prompt now offers EXACTLY TWO outcomes: merge, or stop.

Conditions for the prompt to fire (anything else halts before it):

- Verdict in {`✅ APPROVED`, `✅ APPROVED WITH NOTES`}
- `BLOCKERS == 0`
- `DANGER_ZONE_HIT` unset by Step 3 AND the re-scan below comes back clean
- `--no-merge` flag NOT set
- All required PR checks green (`gh pr checks "$PR"`)

**Independent hard gate — this is gate two of two** (does NOT trust agent text
verdicts): immediately before the prompt, re-scan the merged-target diff
(`origin/<STAGING_BRANCH>..HEAD`) against the danger paths via the SAME shared
helper. This defends against a prompt-injected or compromised reviewer
producing a fake APPROVE on a privileged path (migrations, `.claude/skills/`,
CI workflows, etc.). It is fail-closed and bypass-resistant by design — agent
verdicts can never override §9.

```bash
# Re-source defensively; cross-Step bash state is fragile.
. "$(git rev-parse --show-toplevel)/scripts/danger-zone-scan.sh"
DANGER_HITS=$(danger_zone_scan) || {
  echo "🛑 Cannot verify pre-merge danger-zone scan — origin/<STAGING_BRANCH> unreachable."
  echo "   Fail-closed by design: the gate that stops agent verdicts from"
  echo "   overriding §9 must not run silently. Fetch then retry /ship."
  exit 1
}
if [ -n "$DANGER_HITS" ]; then
  echo "🛑 Pre-merge danger-zone re-scan caught privileged paths even though the verdict was APPROVE."
  echo "   This is the bypass-resistant gate — agent verdicts cannot override §9."
  echo "$DANGER_HITS" | sed 's/^/  - /'
  echo "   Merge manually AFTER human review (option 1 of 3): gh pr merge $PR --squash --delete-branch"
  exit 0
fi

if [ "$VERDICT" = "⚠️ APPROVED-WITH-DISSENT" ]; then
  echo "🟡 Verdict is APPROVED-WITH-DISSENT — refusing to auto-merge. Read the dissent first."
  exit 0
fi
```

### The merge prompt — exactly two outcomes

After the gates pass, surface (substituting `$PR`, `$VERDICT`, `$COMMENT_URL`):

```
✅ PR #$PR is ready to merge.
   Verdict:  $VERDICT
   Blockers: 0
   Danger:   none
   Review:   $COMMENT_URL

Any non-blocker findings (minor + nit) are NOT cause to delay. The
"nits-never-gate-merge" rule: first APPROVED + 0 blockers = ship.

Type 'merge' (or 'ship' / 'yes') to squash-merge to <STAGING_BRANCH>.
Anything else halts without merging.

DO NOT iterate from here to address findings — each fix triggers a fresh
review, surfacing new nits indefinitely. If you genuinely must fix something,
sweep ALL findings in ONE commit outside /ship, then re-invoke.
```

Wait for explicit confirmation. ONLY `merge` / `ship` / `yes` (case-insensitive)
proceed. Anything else halts with `Halted at merge gate by user. PR #$PR left open.`

On confirmation, merge. Try the **standard protected-branch path first** — if
the review bot posted a formal GitHub approval, branch protection's required-
approvals gate is satisfied and the merge logs as a normal merge, not an
admin bypass. Only fall back to `--admin` if the clean merge fails (branch
protection unconfigured, flaky checks, or the bot approval wasn't posted).

```bash
if gh pr merge "$PR" --squash --delete-branch 2>/tmp/ship-merge-err; then
  echo "✓ Merged via standard protected-branch path (bot approval satisfied gate)"
else
  echo "🛈 Non-admin merge failed; falling back to --admin. Reason:"
  sed 's/^/    /' /tmp/ship-merge-err
  gh pr merge "$PR" --admin --squash --delete-branch
fi

# Release the branch lock — branch is squash-merged and gone upstream.
if [ -x "$BRANCH_LOCK" ]; then "$BRANCH_LOCK" release "$BRANCH" 2>/dev/null || true; fi
```

After merge, update the tracker: `<TICKET_ID>` → `In Review` (the staging
deploy is "in review" until `/promote` moves it to Done).

## Step 9 — Final report

```
✅ /ship complete

Ticket:    $TICKET_ID — $TICKET_TITLE
Branch:    $BRANCH (deleted) → <STAGING_BRANCH>
PR:        #$PR
Verdict:   $VERDICT
Tracker:   In Progress → In Review

Next: visually verify on <STAGING_BRANCH>. When ready, /promote to ship to prod.
```

(For halts, show what's pending instead of `complete`.)

## Step 10 — Write a runlog shard

Write a per-invocation audit shard, NOT an append to a shared log file —
parallel ships from different branches would otherwise conflict on the same
file. Each invocation gets its own uniquely-named file under a dated dir.

```bash
# CUSTOMIZE: your per-invocation audit-shard helper.
./scripts/runlog.sh append ship "$TICKET_ID" \
  "<verdict-or-halt-reason> | pr=$PR | branch=$BRANCH | merged=<yes|no>"
```

## Failure modes that halt and surface (NOT errors)

- Pre-push hook failed (CI quick-gates not green) — user fixes locally, re-runs.
- Branch lock held by another session — coordinate or take over.
- Agent review timed out — re-run after it lands, or fire `/agentreview <PR>`.
- Verdict is `❌ NEEDS CHANGES` / `⚠️ APPROVED-WITH-DISSENT` / `🟦 SKIPPED` — push a fix outside /ship, then re-invoke.
- Blockers present — address and re-run.
- Danger-zone files touched — merge manually after human review.
- Iteration cap hit — accept the verdict and merge, or push an empty re-review commit.
- `--no-merge` was passed.
- User did not type `merge` / `ship` / `yes` at the prompt.

## What `/ship` does NOT do

- Does not author code.
- Does not push to `<DEFAULT_BRANCH>`. Ever.
- Does not run `--no-verify` or any hook bypass.
- Does not promote to prod (use `/promote`).
- Does not auto-merge — Step 8 always prompts for explicit confirmation.
- Does not offer "address findings" at the merge prompt — exactly two outcomes (merge / stop) by design.
