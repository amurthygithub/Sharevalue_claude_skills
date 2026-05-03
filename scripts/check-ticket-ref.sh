#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# check-ticket-ref.sh — commit-msg hook
#
# Rejects commits without a "Refs: <TRACKER_TEAM_KEY>-NNN" or
# "Closes <TRACKER_TEAM_KEY>-NNN" line in the message footer.
#
# Optionally validates the ticket exists by hitting the tracker's API
# (skipped silently if <TRACKER>_API_KEY is unset).
#
# Bypass: CI_BYPASS=1 git commit ...   (use sparingly; note it on the PR)
#
# Install:
#   cp scripts/check-ticket-ref.sh .git/hooks/commit-msg
#   chmod +x .git/hooks/commit-msg
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# CUSTOMIZE: your tracker prefix (e.g., TICKET, PROJ, ENG, JIRA)
TICKET_PREFIX="${TICKET_PREFIX:-TICKET}"

if [ -n "${CI_BYPASS:-}" ]; then
  echo "[check-ticket-ref] CI_BYPASS=1 set — skipping ticket-ref check"
  exit 0
fi

COMMIT_MSG_FILE="$1"
COMMIT_MSG=$(cat "$COMMIT_MSG_FILE")

# Allow merge / fixup / revert commits to skip the check
if printf '%s\n' "$COMMIT_MSG" | head -1 | grep -qE '^(Merge|fixup!|squash!|Revert)'; then
  exit 0
fi

# Require Refs: or Closes: with the team prefix
if ! printf '%s\n' "$COMMIT_MSG" | grep -qE "^(Refs|Closes): ${TICKET_PREFIX}-[0-9]+\b"; then
  echo "❌ Commit message must include a footer:" >&2
  echo "     Refs: ${TICKET_PREFIX}-NNN" >&2
  echo "   or" >&2
  echo "     Closes: ${TICKET_PREFIX}-NNN" >&2
  echo "" >&2
  echo "   Bypass once for emergency: CI_BYPASS=1 git commit ..." >&2
  exit 1
fi

# Optional: validate the ticket exists in the tracker
# CUSTOMIZE: replace the curl block with your tracker's API
if [ -n "${LINEAR_API_KEY:-}" ]; then
  TICKET=$(printf '%s\n' "$COMMIT_MSG" | grep -oE "${TICKET_PREFIX}-[0-9]+" | head -1)
  if [ -n "$TICKET" ]; then
    RESP=$(curl -sS -X POST https://api.linear.app/graphql \
      -H "Authorization: $LINEAR_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$(jq -nc --arg id "$TICKET" '{query:"query{issue(id:\($id|tojson))){identifier state{name}}}"}')" \
      2>/dev/null || true)
    STATE=$(printf '%s' "$RESP" | jq -r '.data.issue.state.name // empty' 2>/dev/null || true)
    case "$STATE" in
      "Canceled"|"Duplicate")
        echo "❌ Ticket $TICKET is in '$STATE' — refusing to commit against it." >&2
        echo "   Re-open the ticket or reference a different one." >&2
        exit 1
        ;;
    esac
  fi
fi

exit 0
