#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# check-ticket-ref.sh — commit-msg hook
#
# Rejects commits without a "Refs: <TRACKER_TEAM_KEY>-NNN" or
# "Closes <TRACKER_TEAM_KEY>-NNN" line in the message footer. Optionally
# validates the ticket is live by hitting the tracker's API (skipped
# silently if <TRACKER>_API_KEY is unset — see below).
#
# Two call sites share this script:
#   - the commit-msg hook (one message-file argument)
#   - your --quick CI lane, looped over the branch's commits
#
# Behaviour:
#   - Skips merge / revert / fixup / squash commits — the ref lives on the
#     original commit, not the mechanical one.
#   - Skips (warns, does not fail) when <TRACKER>_API_KEY is unset. This keeps
#     contributors who haven't set up the env var unblocked; PR review still
#     enforces the rule on anything that gets pushed.
#   - Bypass once: CI_BYPASS=1 git commit ...   (use sparingly; note on the PR)
#   - When the key IS set, validates each unique ref and fails if:
#       * no ref present
#       * ref not found in the tracker
#       * ref belongs to a different team than <TRACKER_TEAM_KEY>
#       * ref state is Canceled or Duplicate (pick a live ticket)
#
# Bash 3.2-compatible (works on the default macOS shell).
#
# Install:
#   cp scripts/check-ticket-ref.sh .git/hooks/commit-msg
#   chmod +x .git/hooks/commit-msg
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# CUSTOMIZE: your tracker prefix (e.g., TICKET, PROJ, ENG, JIRA) and API URL.
# Keep TICKET_PREFIX in sync with <TRACKER_TEAM_KEY> in CLAUDE.md and the skills.
TICKET_PREFIX="${TICKET_PREFIX:-TICKET}"           # <TRACKER_TEAM_KEY>
TRACKER_API_BASE="${TRACKER_API_BASE:-<TRACKER_API_BASE>}"

# NEVER hardcode the token here. It comes from the shell env (~/.zshrc etc.),
# exported as <TRACKER>_API_KEY. Do not echo or log its value.
API_KEY="${TRACKER_API_KEY:-}"                     # <TRACKER>_API_KEY

MSG_FILE="${1:-.git/COMMIT_EDITMSG}"
[ -f "$MSG_FILE" ] || exit 0  # nothing to check

# Skip mechanical commits — refs come from the original commit.
HEADER=$(head -1 "$MSG_FILE")
case "$HEADER" in
  Merge*|merge[:\ ]*|Revert*|revert[:\ ]*|"fixup!"*|"squash!"*) exit 0 ;;
esac

# Emergency bypass.
if [ "${CI_BYPASS:-0}" = "1" ]; then
  echo "[check-ticket-ref] CI_BYPASS=1 set — skipping ticket-ref check"
  exit 0
fi

# Structural check first (runs even without an API key): require the footer.
REFS=$(grep -oE "${TICKET_PREFIX}-[0-9]+" "$MSG_FILE" | sort -u || true)
if [ -z "$REFS" ]; then
  echo "❌ Commit message must reference a ticket in its footer:" >&2
  echo "     Refs: ${TICKET_PREFIX}-NNN   (or  Closes: ${TICKET_PREFIX}-NNN)" >&2
  echo "   Bypass once for emergency: CI_BYPASS=1 git commit ..." >&2
  exit 1
fi

# Skip live validation if no API key — don't break devs who haven't set it up.
if [ -z "$API_KEY" ]; then
  echo "[check-ticket-ref] <TRACKER>_API_KEY unset — structural check only (set it to validate live)"
  exit 0
fi

# CUSTOMIZE: replace this block with your tracker's API call + response shape.
# The example below is GraphQL-shaped (Linear-style); adapt the query and the
# jq paths for Jira/GitHub/etc. Keep the three failure classes.
FAIL=0
for ref in $REFS; do
  resp=$(curl -sS -X POST "$TRACKER_API_BASE" \
    -H "Authorization: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg id "$ref" \
        '{query:"query($id:String!){issue(id:$id){identifier state{name} team{key}}}",variables:{id:$id}}')" \
    2>/dev/null || true)

  state=$(printf '%s' "$resp" | jq -r '.data.issue.state.name // empty' 2>/dev/null || true)
  team=$(printf '%s'  "$resp" | jq -r '.data.issue.team.key  // empty' 2>/dev/null || true)

  if [ -z "$state" ]; then
    echo "[check-ticket-ref] $ref not found in tracker" >&2
    FAIL=1
  elif [ "$team" != "$TICKET_PREFIX" ]; then
    echo "[check-ticket-ref] $ref belongs to team '$team' (expected $TICKET_PREFIX)" >&2
    FAIL=1
  elif [ "$state" = "Canceled" ] || [ "$state" = "Duplicate" ]; then
    echo "[check-ticket-ref] $ref state is '$state' — pick a live ticket" >&2
    FAIL=1
  else
    echo "[check-ticket-ref] $ref ($state) ok"
  fi
done

exit $FAIL
