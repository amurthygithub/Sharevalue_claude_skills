#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# cleanup-agent-reviews.sh — reap orphaned agent-review process trees (template)
#
# Background: the pre-push hook spawns a detached background agent review
# (`nohup <agent-cli> --print "/agentreview <PR>"`). When a push is retried
# (a CI gate failed, you fixed it and re-pushed), the prior background agent
# and ITS descendants (sub-agent processes, test runners, etc.) may still be
# running. The hook's per-PR debounce only kills the recorded parent PID —
# descendants reparent to init and keep running, accumulating memory across
# pushes. This script reaps those orphans.
#
# It walks every `$GIT_COMMON_DIR/.agent-review-pr*.pid` file and:
#   - Removes stale lockfiles (recorded PID is dead).
#   - Kills the descendant tree of any LIVE PID older than an in-flight
#     guard (default 600s). Trees younger than that are assumed to be a
#     genuine in-flight review and left alone — this is what stops a push to
#     PR A from nuking PR B's in-flight review in a parallel-worktree setup
#     (a real failure mode we hit before the age guard existed).
#
# The age guard must sit comfortably past the review skill's own poll window
# (the bundled /agentreview polls ~5 min) so a genuinely-stuck tree gets
# reaped on the next push, but a healthy one never does.
#
# WARNING — keep the kill target narrowly scoped. This only ever kills PIDs
# recorded in `.agent-review-pr*.pid` lockfiles AND their descendants. Do NOT
# broaden the match to `pkill <agent-cli>` or a name-based sweep: that would
# kill the operator's interactive agent session and every sibling worktree's
# review. The lockfile is the allowlist — never kill a PID you did not write.
#
# Usage:
#   ./scripts/cleanup-agent-reviews.sh                  # verbose, age-guarded
#   ./scripts/cleanup-agent-reviews.sh --quiet          # summary only
#   ./scripts/cleanup-agent-reviews.sh --force          # ignore the age guard
#   CLEANUP_MIN_AGE_SECONDS=300 ./scripts/cleanup-agent-reviews.sh
#
# Exit codes: always 0 — best-effort cleanup must never block a push.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# ── Process-tree kill helper ─────────────────────────────────────────────────
# Recursively TERM a process and all its descendants, children-before-parent so
# nothing reparents to init mid-kill. bash 3.2-safe (macOS): no `mapfile`.
# CUSTOMIZE: if you keep several scripts that walk process trees, factor this
# into a sourced lib (e.g. scripts/_lib/proc-tree.sh) instead of re-rolling it.
kill_tree() {
  local pid="$1" child
  [ -n "$pid" ] || return 0
  while IFS= read -r child; do
    [ -n "$child" ] || continue
    kill_tree "$child"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
}

QUIET=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    --force) FORCE=1 ;;
    *) ;;
  esac
done

# Trees younger than this are presumed in-flight and skipped (unless --force).
MIN_AGE_SECONDS="${CLEANUP_MIN_AGE_SECONDS:-600}"

GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)" || {
  [ $QUIET -eq 0 ] && echo "cleanup: not inside a git repo" >&2
  exit 0
}
case "$GIT_COMMON_DIR" in
  /*) ;;
  *)  GIT_COMMON_DIR="$(pwd)/$GIT_COMMON_DIR" ;;
esac

# Portable `ps -o etime=` parser → seconds. Handles "mm:ss", "hh:mm:ss",
# and "d-hh:mm:ss". Echoes seconds, or empty if the PID is gone.
# `10#` forces base-10 so "08"/"09" aren't misparsed as octal.
_pid_age_seconds() {
  local pid=$1 etime
  etime="$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')"
  [ -z "$etime" ] && return 0

  local days=0 hours=0 mins=0 seconds=0
  if [[ "$etime" == *-* ]]; then
    days="${etime%%-*}"
    etime="${etime##*-}"
  fi
  local IFS=:
  # shellcheck disable=SC2206
  local parts=( $etime )
  case ${#parts[@]} in
    2) mins=${parts[0]}; seconds=${parts[1]} ;;
    3) hours=${parts[0]}; mins=${parts[1]}; seconds=${parts[2]} ;;
    *) return 0 ;;
  esac
  days=$((10#${days:-0})); hours=$((10#${hours:-0}))
  mins=$((10#${mins:-0})); seconds=$((10#${seconds:-0}))
  echo $((days * 86400 + hours * 3600 + mins * 60 + seconds))
}

killed=0
stale=0
skipped=0
for lock in "$GIT_COMMON_DIR"/.agent-review-pr*.pid; do
  [ -f "$lock" ] || continue

  pid="$(cat "$lock" 2>/dev/null || true)"
  case "$pid" in
    ''|*[!0-9]*) rm -f "$lock"; stale=$((stale + 1)); continue ;;
  esac

  if ! kill -0 "$pid" 2>/dev/null; then
    # PID is dead — stale lockfile, harmless.
    stale=$((stale + 1)); rm -f "$lock"; continue
  fi

  pr_num="${lock##*-pr}"; pr_num="${pr_num%.pid}"

  if [ $FORCE -eq 0 ]; then
    age="$(_pid_age_seconds "$pid")"
    if [ -n "$age" ] && [ "$age" -lt "$MIN_AGE_SECONDS" ]; then
      [ $QUIET -eq 0 ] && \
        echo "cleanup: skipping PR #$pr_num — review pid $pid is ${age}s old (< ${MIN_AGE_SECONDS}s, assumed in-flight)"
      skipped=$((skipped + 1)); continue
    fi
  fi

  [ $QUIET -eq 0 ] && echo "cleanup: killing agent-review tree for PR #$pr_num (root pid $pid)"
  kill_tree "$pid"
  killed=$((killed + 1))
  rm -f "$lock"
done

if [ $QUIET -eq 0 ] || [ $killed -gt 0 ]; then
  echo "cleanup-agent-reviews: $killed tree(s) killed, $stale stale lockfile(s) removed, $skipped in-flight skipped"
fi

exit 0
