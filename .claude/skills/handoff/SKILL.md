---
name: handoff
description: Snapshot the active ticket session (done / tried-and-failed / next step + git state) into a gitignored .claude/handoff-notes.md so a fresh agent resumes without re-walking dead ends.
argument-hint: --note "<tried-and-failed; do-not-retry>" [--did "<done>"] [--next "<exact next step>"]
allowed-tools: Bash
user-invocable: true
disable-model-invocation: false
---

Capture a mid-session handoff snapshot for the active ticket. Run when context is
running low, before closing a long worktree session, or when handing a half-built
feature to a fresh agent.

Why a separate sidecar: `/work-on` rewrites `.claude/active-ticket.md` on every
re-entry, so anything written there is lost on the next session. Handoff state
goes to a **gitignored** `.claude/handoff-notes.md` instead — durable across
sessions, never committed, never clobbered. This skill is a single Bash block
with no hooks; it never touches `work-on`, `ship`, or `settings.json`.

## Contract

- **Input:** `--note` is REQUIRED (the tried-and-failed / do-not-retry text);
  `--did` and `--next` are optional. Arg-based, never interactive — if `--note`
  is absent, print the usage line and exit 1.
- **Side effect:** appends one snapshot block to `.claude/handoff-notes.md` and
  one audit shard via `scripts/runlog.sh`.
- **Refusals (fail-closed):**
  - Not inside the repo → exit 1.
  - No `.claude/active-ticket.md` → exit 1 (nothing to hand off; run `/work-on`).
  - `.claude/handoff-notes.md` is NOT gitignored → exit 1. This guard is
    load-bearing: the note body may contain dead-end debugging prose, and
    writing it to a tracked file would leak it into git history. The skill
    refuses to write until the path is confirmed gitignored.

## The block

Run exactly this one block. Fill `NOTE` / `DID` / `NEXT` from the parsed args as
**single-quoted** literals (escape an embedded single quote as `'\''`); pass `''`
for `DID`/`NEXT` when not supplied.

```bash
cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || { echo "Run /handoff from inside the repo."; exit 1; }
NOTE='<--note value>'; DID='<--did value or empty>'; NEXT='<--next value or empty>'
case "$DID"  in '<'*'>') DID='';;  esac
case "$NEXT" in '<'*'>') NEXT='';; esac
case "$NOTE" in ''|'<'*'>') echo 'Usage: /handoff --note "<tried-and-failed; do-not-retry>" [--did "..."] [--next "..."]  (--note required)'; exit 1;; esac

[ -f .claude/active-ticket.md ] || { echo "No .claude/active-ticket.md here; run /work-on <TRACKER_TEAM_KEY>-NNN first."; exit 1; }
# Fail-closed gitignore guard — never write dead-end prose to a tracked file.
grep -qxF '.claude/handoff-notes.md' .gitignore || { echo "Refusing to write: .claude/handoff-notes.md is not gitignored."; exit 1; }

# CUSTOMIZE: match your tracker's ticket-id shape (e.g. TICKET-123) in the
# active-ticket.md header and in the branch-drift check below.
TICKET=$(grep -m1 -oE '^# Active ticket: <TRACKER_TEAM_KEY>-[0-9]+' .claude/active-ticket.md | grep -oE '<TRACKER_TEAM_KEY>-[0-9]+')
[ -n "$TICKET" ] || { echo "Could not read a ticket id from the active-ticket.md header."; exit 1; }

BRANCH=$(git rev-parse --abbrev-ref HEAD); SHA=$(git rev-parse --short HEAD); NUM=${TICKET#<TRACKER_TEAM_KEY>-}
case "$BRANCH" in
  *"$NUM"*) ;;
  *) echo "WARN: branch '$BRANCH' does not match $TICKET (possible worktree drift); writing anyway." ;;
esac

{
  printf '\n## Handoff snapshot: %s @ %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SHA"
  printf '**Ticket:** %s  **Branch:** %s\n\n' "$TICKET" "$BRANCH"
  printf '### Done (confirmed)\n%s\n\n' "${DID:-_(not specified)_}"
  printf '### Tried and failed (DO NOT RETRY)\n%s\n\n' "$NOTE"
  printf '### Next step\n%s\n\n' "${NEXT:-_(not specified)_}"
  printf '### Current file state\n```\n'; git diff --stat HEAD; printf '\nrecent commits:\n'; git log --oneline -5; printf '```\n'
} >> .claude/handoff-notes.md

# Audit shard body carries ONLY branch + sha (no user prose) so the committed
# trail stays PII-free. The note text lives only in the gitignored sidecar.
./scripts/runlog.sh append handoff "$TICKET" "snapshot | branch=$BRANCH | sha=$SHA"

echo "Handoff snapshot appended to .claude/handoff-notes.md (@ $SHA)"
echo "Resume with: /work-on $TICKET, then Read .claude/handoff-notes.md"
```

## What `/handoff` does NOT do

- Does not write to `.claude/active-ticket.md` (`/work-on` owns that file).
- Does not commit, push, or touch any tracked file.
- Does not put the note prose into the audit trail — only `branch` + `sha`.
