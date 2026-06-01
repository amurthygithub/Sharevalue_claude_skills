---
name: promote
description: Promote <STAGING_BRANCH> → <DEFAULT_BRANCH> (production). USER-INVOKED ONLY. Opens a promote PR, posts a "promotion ready" digest, and waits for the user's explicit confirmation before merging. Tags + drafts a release on merge.
argument-hint: '[--cherry-pick PR1,PR2,...] [--skip-soak] [--message "..."] [--major|--minor]'
allowed-tools: Bash, Read, Write
user-invocable: true
disable-model-invocation: true
---

You are promoting changes from `<STAGING_BRANCH>` to `<DEFAULT_BRANCH>` (production). This is the **prod gate**. The user explicitly invoked you and is in the loop for the merge decision. **NEVER** merge without their explicit go-ahead in this session.

`disable-model-invocation: true` is intentional: only the human can fire `/promote`. If you (a sub-agent or autonomous loop) think you should run `/promote`, **stop and ask the user**.

## Inputs

| Flag | Meaning |
|---|---|
| `--cherry-pick PR1,PR2,...` | Curate a branch off `<DEFAULT_BRANCH>` with only those PRs cherry-picked. |
| `--skip-soak` | Skip the "has staging soaked >24h" advisory (user accepts urgent risk). |
| `--message "..."` | Override default PR title. |
| `--major` / `--minor` | Override default patch version bump. |

## Step 1 — Validate

```bash
git fetch origin --quiet
git rev-parse origin/<DEFAULT_BRANCH> >/dev/null
git rev-parse origin/<STAGING_BRANCH> >/dev/null
```

## Step 2 — Compute the promotion set

```bash
# Commits on staging not yet on main, chronological. %B captures the full
# body (not just the subject) so ticket refs that live in `Refs:` footers —
# not always echoed into the squash-merge subject — stay reachable for the
# Done-marking step.
git log --no-merges --pretty='%h %B' origin/<DEFAULT_BRANCH>..origin/<STAGING_BRANCH> > /tmp/promote-commits.txt
gh pr list --state merged --base <STAGING_BRANCH> --limit 50 --json number,title,mergedAt,mergeCommit \
  --jq '.[] | "\(.number)\t\(.mergedAt)\t\(.title)"' > /tmp/promote-prs.txt
```

Print a structured digest of: commits ahead, PRs merged (newest first), files
touched (top-20 by churn), and **danger-zone touches**.

The danger-zone section uses the same `<DANGER_PATHS_REGEX>` as
`.claude/skills/ship/SKILL.md` (see CLAUDE.md §9.2). For `/promote` this is
**informational** — the human gate at Step 4 is the enforcement point. Surface
the hits so the user can weigh them before typing `yes`.

For `--cherry-pick PR1,PR2`, reduce the set to just those PRs' merge commits.

## Step 3 — Soak window check (advisory, not blocking)

If the oldest unpromoted PR's `mergedAt` is less than 24 h ago, print a soak
warning (the convention lets nightly/scheduled jobs run a full cycle on staging
before prod). `--skip-soak` overrides.

## Step 4 — Surface and PAUSE FOR USER CONFIRMATION

```
⚠️ Ready to promote. This will open PR <to-be-determined> targeting <DEFAULT_BRANCH>.

  Commits: <N>
  PRs:     <list>
  Soak:    <ok|warning>
  Danger:  <none|list>

Type 'yes' to open the promote PR. Anything else aborts.
```

**Wait for an explicit, present-tense `yes`. Do NOT proceed without it.** If
your runtime blocks interactive input when `disable-model-invocation: true`,
print:

```
🛑 /promote needs interactive confirmation. Re-run from your terminal session, not from a sub-agent.
```

and exit.

## Step 5 — Build the promotion branch

```bash
PROMO_BRANCH="chore/promote-$(date +%Y%m%d-%H%M)"
git checkout -B "$PROMO_BRANCH" origin/<DEFAULT_BRANCH>
git merge --no-ff --no-edit origin/<STAGING_BRANCH>
git push -u origin "$PROMO_BRANCH"
```

For `--cherry-pick`, cherry-pick each PR's merge commit individually; abort and
surface on the first conflict.

## Step 6 — Open the promote PR

```bash
gh pr create \
  --base <DEFAULT_BRANCH> \
  --head "$PROMO_BRANCH" \
  --title "chore(infra): promote staging to main $(date +%Y-%m-%d) (<short summary>)" \
  --body "$(cat <<EOF
## Promotion: <STAGING_BRANCH> → <DEFAULT_BRANCH>

### Included PRs
<list with #N — title>

### Soak status
<ok|warning + duration>

### Danger-zone touches
<none|list of paths>

### Test plan (post-merge)
- [ ] Production deploy goes green
- [ ] No new errors in observability dashboards (30 min)
- [ ] Key public endpoints reachable

### Rollback
\`gh pr revert <merged-PR-number>\` and push to <DEFAULT_BRANCH>.

🤖 Auto-opened by \`/promote\` — user retains explicit merge gate.
EOF
)"
PROMO_PR=$(gh pr view "$PROMO_BRANCH" --json number -q .number)
```

## Step 7 — Wait for CI

```bash
gh pr checks "$PROMO_PR" --watch --interval 30 --fail-fast || {
  echo "❌ CI failed on promote PR. Inspect, fix, and re-run /promote."
  exit 1
}
```

## Step 8 — Final confirmation + merge

```
✅ Promote PR #$PROMO_PR ready to merge.
   CI: green
   URL: <pr-url>

Type 'ship' to merge to <DEFAULT_BRANCH> and trigger prod deploy. Anything else aborts.
```

**Wait for `ship`** (or equivalent positive). On confirmation:

```bash
# Use --merge (not --squash) so staging's commits become reachable from
# <DEFAULT_BRANCH> via the merge commit's second-parent line. Squashing N
# commits into 1 leaves staging permanently counted "N commits ahead" in the
# GitHub UI, which compounds across promote cycles. The promo branch already
# has staging merged into it (Step 5), so <DEFAULT_BRANCH> transitively
# reaches staging-tip after this merge; Step 9.5 then pulls back to converge.
gh pr merge "$PROMO_PR" --admin --merge --delete-branch
```

If your runtime blocks input here, print the merge command for the user to run
themselves and exit. **Never auto-merge to production.**

## Step 9 — Tag + draft GitHub release

Patch bump is the default; `--major` / `--minor` override. Tags are
`vMAJOR.MINOR.PATCH`.

```bash
# Refresh origin before computing the bump and tagging — otherwise the tag
# could land on a stale ref and miss the just-merged commit.
git fetch origin <DEFAULT_BRANCH> --quiet
LAST_TAG=$(git describe --tags --abbrev=0 origin/<DEFAULT_BRANCH> 2>/dev/null || echo "v0.0.0")
VERSION="${LAST_TAG#v}"
MAJOR=$(echo "$VERSION" | awk -F. '{print ($1+0)}')
MINOR=$(echo "$VERSION" | awk -F. '{print ($2+0)}')
PATCH=$(echo "$VERSION" | awk -F. '{print ($3+0)}')
case "$ARGUMENTS" in
  *--major*) MAJOR=$((MAJOR+1)); MINOR=0; PATCH=0 ;;
  *--minor*) MINOR=$((MINOR+1)); PATCH=0 ;;
  *)         PATCH=$((PATCH+1)) ;;
esac
NEW_TAG="v${MAJOR}.${MINOR}.${PATCH}"

git tag -a "$NEW_TAG" -m "Promote $(date +%Y-%m-%d): <summary>" $(git rev-parse origin/<DEFAULT_BRANCH>)
git push origin "$NEW_TAG"

gh release create "$NEW_TAG" \
  --target <DEFAULT_BRANCH> \
  --title "$NEW_TAG — $(date +%Y-%m-%d) prod promote" \
  --notes "..." \
  --draft
```

The release is left as a **draft** — finalize it after the soak window confirms
prod is healthy.

## Step 9.5 — Merge <DEFAULT_BRANCH> back into <STAGING_BRANCH> (graph convergence)

After the production merge + tag land, merge back so the GitHub UI shows
0 ahead / 0 behind. Without this, the next `/promote` re-conflicts on
already-merged content for no benefit.

```bash
git fetch origin <DEFAULT_BRANCH> --quiet
# -B creates-or-resets the local branch from origin — avoids a pathspec error
# on a fresh checkout that never had <STAGING_BRANCH> checked out locally.
git checkout -B <STAGING_BRANCH> origin/<STAGING_BRANCH>
# Strip anything outside [A-Za-z0-9._-] before splicing $NEW_TAG into the
# commit subject — defensive against a corrupt tag injecting shell-active text.
SAFE_TAG="${NEW_TAG//[^A-Za-z0-9._-]/}"
# CUSTOMIZE: derive the promoted ticket list for the Refs footer below, e.g.
#   PROMOTED_TICKETS=$(grep -oE '<TRACKER_TEAM_KEY>-[0-9]+' /tmp/promote-commits.txt \
#     | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')
# The subject MUST use a Conventional Commits type — `chore(infra):` fits.
# A `Merge:` subject is rejected by the conventional-commits hook (merge isn't
# an allowed type), so it dies before any ticket-ref hook runs.
git merge --no-ff origin/<DEFAULT_BRANCH> -m "$(cat <<EOF
chore(infra): merge <DEFAULT_BRANCH> back into <STAGING_BRANCH> post $SAFE_TAG promote

No content changes — reconciles graph divergence after the promote so the
GitHub UI shows 0 ahead / 0 behind and the next /promote won't re-conflict.

Refs: <PROMOTED_TICKETS>
EOF
)"
git push origin <STAGING_BRANCH>
```

If branch protection blocks the direct push (e.g. "Required reviews"), surface
the error and continue — this convergence merge is nice-to-have, not blocking.

## Step 10 — Update tracker: tickets → Done

For every `Refs: <TRACKER_TEAM_KEY>-NNN` footer in the merged commits, mark the
ticket Done via `/linear update <id> status:Done` (or inline a tracker mutation
against `<TRACKER_STATE_DONE_UUID>`).

## Step 11 — Post-deploy verification (best-effort)

```bash
# CUSTOMIZE: probe 2-3 critical public routes on <PROD_DOMAIN> and assert
# response codes / cache headers. Surface anomalies as WARNINGS — never roll
# back automatically. Example skeleton:
#
#   for path in / /health /api/<critical-public-route>; do
#     code=$(curl -s -o /dev/null -w '%{http_code}' "https://<PROD_DOMAIN>${path}")
#     [ "$code" = "200" ] || echo "🟡 ${path} returned ${code} — investigate"
#   done
#
# Note: a vendor-fronted prod (CDN / bot-mitigation / WAF) may serve different
# cache headers to plain curl than to a real browser. If header assertions are
# load-bearing, prefer (a) a CI-time test that imports your framework's header
# config and asserts per-route resolution, plus (b) a headless-browser probe
# against live prod. Keep both in sync.
```

## Step 12 — Final report

```
🚀 Promoted to prod

Tag:        $NEW_TAG
PR:         #$PROMO_PR
Tickets:    <list of <TRACKER_TEAM_KEY>-NNN → Done>
Verify:     <ok|warning>
Release:    <draft url — finalize when soak complete>

Soak window: monitor observability for 30 min.
```

## Step 13 — Append to the run log

Write a per-invocation shard rather than appending to a single shared file —
parallel sessions then never conflict on the audit trail.

```bash
# CUSTOMIZE: point at your own run-log helper. Shards live under a dated dir,
# e.g. docs/agent-evolution/runs/<UTC-date>/, and are committed to git.
./scripts/runlog.sh append promote "-" \
  "done | tag=$NEW_TAG | promo_pr=$PROMO_PR | tickets=<list> | verify=<ok|warning>"
```

## What `/promote` HALTS on (no auto-merge to production)

- User did not type `yes` at Step 4.
- CI failed at Step 7.
- User did not type `ship` at Step 8.
- Cherry-pick conflict at Step 5.

## What `/promote` does NOT do

- Does not auto-fire from any other skill or hook.
- Does not run from a non-interactive shell (the confirmation gates require interactive input).
- Does not skip the user-confirmation gates regardless of flags.
- Does not roll back automatically — user calls `gh pr revert` if prod is bad.
