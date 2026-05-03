---
name: ship
description: Ship the current feature branch to <STAGING_BRANCH> — commit any uncommitted changes, push (triggers pre-push hook + agent review), open PR if missing, wait for 2-of-3 consensus, merge to <STAGING_BRANCH> unless blockers or danger-zone hits.
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

## Step 2 — Determine the ticket

Priority order:

1. `.claude/active-ticket.md` — top line `# Active ticket: <TRACKER_TEAM_KEY>-NNN — <title>`.
2. Branch name pattern `<prefix>/<ticket-id-lowercased>-...` — derive ticket id (uppercased).
3. Last commit's `Refs: <TRACKER_TEAM_KEY>-NNN` footer.

If none resolves a ticket, abort.

## Step 3 — Detect danger-zone touches BEFORE committing

```bash
# CUSTOMIZE: keep this regex in sync with CLAUDE.md §9.2
DANGER_PATHS='<DANGER_PATHS_REGEX>'

{
  git diff --name-only origin/<STAGING_BRANCH> HEAD 2>/dev/null
  git diff --name-only HEAD          # unstaged
  git diff --name-only --cached      # staged
} | sort -u | grep -E "$DANGER_PATHS" > /tmp/ship-danger.txt || true

if [ -s /tmp/ship-danger.txt ]; then
  echo "🛑 Danger-zone files in this change set:"
  sed 's/^/  - /' /tmp/ship-danger.txt
  echo "These require manual review per CLAUDE.md §9. /ship will commit + push + run review,"
  echo "but will NOT auto-merge."
  DANGER_ZONE_HIT=1
fi
```

`DANGER_ZONE_HIT` is consulted at Step 8.

## Step 4 — Stage and commit any uncommitted changes

If working tree is clean, skip.

```bash
git add -A
# Belt-and-suspenders unstage of obvious secrets
git reset HEAD -- '*.env' '.env*' '*.key' '*.pem' '*credentials*' 2>/dev/null || true
```

Build the commit message:

- Subject: pick a Conventional Commits prefix (`feat|fix|chore|refactor|docs|perf|test|ci|build`) based on `<branch-prefix>` from the branch name, else infer from `TICKET_TITLE`. Default: `chore`.
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

1. Run `ci-local.sh --quick`. Non-zero → push aborted.
2. If a PR exists for this branch, fire `/agentreview` in the background.

## Step 6 — Open the PR if it doesn't exist

The pre-push hook only fires `/agentreview` when a PR already exists. On the first `/ship` for a new branch, the push happens before the PR — so we explicitly fire the review after opening the PR.

```bash
NEWLY_OPENED=0
PR=$(gh pr view "$BRANCH" --json number -q .number 2>/dev/null || echo "")

# Early-exit if PR is already merged
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

if [ "$NEWLY_OPENED" = "1" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel)
  LOG="$REPO_ROOT/.git/.agent-review-pr${PR}.log"
  LOCK="$REPO_ROOT/.git/.agent-review-pr${PR}.pid"
  if [ -f "$LOCK" ]; then
    OLD_PID="$(cat "$LOCK" 2>/dev/null)"
    case "$OLD_PID" in ''|*[!0-9]*) OLD_PID="" ;; esac
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
      kill "$OLD_PID" 2>/dev/null || true
    fi
  fi
  ( cd "$REPO_ROOT" && nohup <agent-cli> --print --permission-mode bypassPermissions "/agentreview $PR" >"$LOG" 2>&1 ) &
  REVIEW_PID=$!
  echo "$REVIEW_PID" > "$LOCK"
  disown 2>/dev/null || true
fi
```

## Step 7 — Wait for agent-review consensus

Poll up to 5 minutes (timeout = halt for user). The review skill posts a comment whose body starts with `## 🤖 Agent Consensus Review`. We want the latest such comment whose `**SHA reviewed:**` matches the current `HEAD` short SHA.

```bash
HEAD_SHORT=$(git rev-parse --short HEAD)
DEADLINE=$(($(date +%s) + 300))
VERDICT=""; BLOCKERS=0; COMMENT_URL=""

while [ $(date +%s) -lt $DEADLINE ]; do
  COMMENT=$(gh pr view "$PR" --json comments -q "
    .comments[-20:] | reverse
    | map(select(.body | startswith(\"## 🤖 Agent Consensus Review\")))
    | map(select(.body | contains(\"$HEAD_SHORT\")))
    | .[0]")
  if [ "$COMMENT" != "null" ] && [ -n "$COMMENT" ]; then
    BODY=$(jq -r '.body' <<<"$COMMENT")
    VERDICT=$(grep -E '^\*\*Verdict:\*\*' <<<"$BODY" \
              | grep -oE '✅ APPROVED( WITH NOTES)?|⚠️ APPROVED-WITH-DISSENT|❌ NEEDS CHANGES' \
              | head -1)
    BLOCKERS=$(grep -cE '^- \[SEVERITY: blocker\]' <<<"$BODY" | tr -d ' ')
    break
  fi
  sleep 15
done
```

| Outcome | Action |
|---|---|
| `VERDICT` empty (timeout) | `⏱ Agent review didn't post in 5 min. Check $LOG and re-run /ship.` Exit 1. |
| `❌ NEEDS CHANGES` | Print verdict + comment URL + findings. Exit 1, no merge. |
| `⚠️ APPROVED-WITH-DISSENT` | Print verdict + dissent. Halt for user — do NOT merge. |
| `✅ APPROVED(_WITH_NOTES)` and `BLOCKERS == 0` | Proceed to Step 8. |
| `BLOCKERS > 0` (any verdict) | Halt regardless. Print blockers. |

## Step 8 — Merge to `<STAGING_BRANCH>` (only if all gates green)

Conditions:

- Verdict in {`✅ APPROVED`, `✅ APPROVED WITH NOTES`}
- `BLOCKERS == 0`
- `DANGER_ZONE_HIT` unset
- `--no-merge` flag NOT set
- All required PR checks green

**Independent hard gate** (does NOT trust agent text verdicts): immediately before the merge, re-scan the change set against `DANGER_PATHS`. This defends against any compromised reviewer producing a fake APPROVE on a privileged path.

```bash
DANGER_HITS=$(git diff --name-only origin/<STAGING_BRANCH> HEAD | grep -E "$DANGER_PATHS" || true)
if [ -n "$DANGER_HITS" ]; then
  echo "🛑 Pre-merge danger-zone re-scan caught files even though agent verdict was APPROVE."
  echo "$DANGER_HITS" | sed 's/^/  - /'
  echo "   Merge manually after human review."
  exit 0
fi

if [ "$VERDICT" = "⚠️ APPROVED-WITH-DISSENT" ]; then
  echo "🟡 Verdict is APPROVED-WITH-DISSENT — refusing to auto-merge."
  exit 0
fi

gh pr merge "$PR" --admin --squash --delete-branch
```

After merge, update the tracker: `<TICKET_ID>` → `In Review`.

## Step 9 — Final report

```
✅ /ship complete

Ticket:    $TICKET_ID — $TICKET_TITLE
Branch:    $BRANCH (deleted) → <STAGING_BRANCH>
PR:        #$PR
Verdict:   $VERDICT
Tracker:   In Progress → In Review

Next: visually verify on staging. When ready, /promote to ship to prod.
```

## Step 10 — Append to RUN_LOG

```bash
echo "<ISO UTC> | /ship | <verdict-or-halt-reason> | ticket=$TICKET_ID | pr=$PR | merged=<yes|no>" \
  >> docs/agent-evolution/RUN_LOG.md
```

## Failure modes that halt and surface (NOT errors)

- Pre-push hook failed (CI quick-gates not green)
- Agent review timed out
- Verdict is `❌ NEEDS CHANGES` or `⚠️ APPROVED-WITH-DISSENT`
- Blockers present
- Danger-zone files touched
- `--no-merge` was passed

## What `/ship` does NOT do

- Does not author code.
- Does not push to `<DEFAULT_BRANCH>`.
- Does not run `--no-verify` or any hook bypass.
- Does not promote to prod (use `/promote`).
