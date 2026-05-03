---
name: promote
description: Promote <STAGING_BRANCH> → <DEFAULT_BRANCH> (production). USER-INVOKED ONLY. Opens a promote PR, posts a "promotion ready" digest, and waits for the user's explicit confirmation before merging. Tags + drafts a release on merge.
argument-hint: '[--cherry-pick PR1,PR2,...] [--skip-soak] [--message "..."]'
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
| `--skip-soak` | Skip the "has staging soaked >24h" advisory. |
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
git log --no-merges --pretty='%h %s' origin/<DEFAULT_BRANCH>..origin/<STAGING_BRANCH> > /tmp/promote-commits.txt
gh pr list --state merged --base <STAGING_BRANCH> --limit 50 --json number,title,mergedAt,mergeCommit \
  --jq '.[] | "\(.number)\t\(.mergedAt)\t\(.title)"' > /tmp/promote-prs.txt
```

Print a structured digest of: commits ahead, PRs merged (newest first), files touched (top-20 by churn), danger-zone touches.

## Step 3 — Soak window check (advisory, not blocking)

If the oldest unpromoted PR's `mergedAt` is less than 24 h ago, print a soak warning. `--skip-soak` overrides.

## Step 4 — Surface and PAUSE FOR USER CONFIRMATION

```
⚠️ Ready to promote. This will open PR <to-be-determined> targeting <DEFAULT_BRANCH>.

  Commits: <N>
  PRs:     <list>
  Soak:    <ok|warning>
  Danger:  <none|list>

Type 'yes' to open the promote PR. Anything else aborts.
```

**Wait for an explicit `yes` (or equivalent). Do NOT proceed without it.**

## Step 5 — Build the promotion branch

```bash
PROMO_BRANCH="chore/promote-$(date +%Y%m%d-%H%M)"
git checkout -B "$PROMO_BRANCH" origin/<DEFAULT_BRANCH>
git merge --no-ff --no-edit origin/<STAGING_BRANCH>
git push -u origin "$PROMO_BRANCH"
```

For `--cherry-pick`, cherry-pick each PR's merge commit individually.

## Step 6 — Open the promote PR

```bash
gh pr create \
  --base <DEFAULT_BRANCH> \
  --head "$PROMO_BRANCH" \
  --title "$(date +%Y-%m-%d) promote: <message-or-summary>" \
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

Type 'ship' to merge to <DEFAULT_BRANCH> and trigger prod deploy. Anything else aborts.
```

**Wait for `ship`** (or equivalent positive). On confirmation:

```bash
gh pr merge "$PROMO_PR" --admin --squash --delete-branch
```

## Step 9 — Tag + draft GitHub release

```bash
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

## Step 10 — Update tracker: tickets → Done

For every `Refs: <TRACKER_TEAM_KEY>-NNN` footer in the merged commits, mark the ticket Done via `/linear update <id> status:Done` (or your tracker's equivalent).

## Step 11 — Post-deploy verification (best-effort)

Curl 2-3 critical public endpoints with appropriate bypass headers and verify response codes / cache headers. Surface anomalies as warnings — do NOT roll back automatically.

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

## Step 13 — Append to RUN_LOG

```bash
echo "<ISO UTC> | /promote | done | tag=$NEW_TAG | promo_pr=$PROMO_PR | tickets=<list>" \
  >> docs/agent-evolution/RUN_LOG.md
```

## What `/promote` HALTS on (no auto-merge)

- User did not type `yes` at Step 4.
- CI failed at Step 7.
- User did not type `ship` at Step 8.
- Cherry-pick conflict at Step 5.

## What `/promote` does NOT do

- Does not auto-fire from any other skill or hook.
- Does not run from a non-interactive shell.
- Does not skip the user-confirmation gates regardless of flags.
- Does not roll back automatically — user calls `gh pr revert` if prod is bad.
