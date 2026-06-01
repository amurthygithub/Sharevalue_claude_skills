#!/usr/bin/env bash
# agentreview-watch.sh — watcher for an in-flight /agentreview run.
#
# WHY this exists: a multi-minute background job (the /agentreview council)
# must NEVER go dark. "Silence is not success" — a watcher that only prints
# on the happy path can't be distinguished from one that wedged. So this
# script emits a TERMINAL line on EVERY end state, plus a periodic heartbeat
# while running. Wire it up so each stdout line becomes a notification (e.g.
# the agent runtime's background-process monitor). Output is sparse-by-design.
#
# State machine — exactly one terminal line, then exit:
#
#   [start]      one line on attach (records pid + log path)
#   [heartbeat]  every HEARTBEAT_INTERVAL seconds while running
#   [verdict]    on the orchestrator's completion signal (success summary)
#   [skipped]    on a no-council short-circuit (e.g. docs-only change)
#   [stall]      log untouched for STALL_THRESHOLD seconds AFTER it first
#                became non-empty (the agent CLI is silent-until-done by
#                design, so a 0-byte log mid-run is normal, not a stall)
#   [failure]    pid is dead with no verdict, OR the log file vanished mid-run
#   [timeout]    total wall time exceeds MAX_WAIT
#
# Exit codes: 0 on verdict (incl. skipped), 1 on every other terminal state.
#
# Pairs with the spawn helper (your /ship or pre-push hook), which writes:
#   <STATE_DIR>/.agent-review-pr<N>.log    (orchestrator stdout)
#   <STATE_DIR>/.agent-review-pr<N>.pid    (orchestrator pid)
# Both detached (pre-push hook) and in-session spawns share that contract.

# Intentional: `set -uo pipefail` omits `-e`. This is a poll loop — individual
# command failures (stat on a missing file, grep no-match, kill -0 on a dead
# pid) are normal control-flow signals here, not abort conditions. `-u` +
# `pipefail` still catch unset-var bugs and pipe-stage failures.
set -uo pipefail

PR_NUMBER="${1:-}"
if [ -z "$PR_NUMBER" ] || ! [ "$PR_NUMBER" -eq "$PR_NUMBER" ] 2>/dev/null \
    || [ "$PR_NUMBER" -le 0 ]; then
  echo "[failure] usage: scripts/agentreview-watch.sh <PR_NUMBER>"
  exit 1
fi

# Heartbeat ~3min, stall ~10min — tuned for a council that runs ~5min on the
# happy path. All env-overridable so a slower runtime can relax them.
HEARTBEAT_INTERVAL="${AGENTREVIEW_WATCH_HEARTBEAT:-180}"
STALL_THRESHOLD="${AGENTREVIEW_WATCH_STALL:-600}"
MAX_WAIT="${AGENTREVIEW_WATCH_TIMEOUT:-1800}"
POLL_INTERVAL="${AGENTREVIEW_WATCH_POLL:-15}"

# Resolve the shared state dir the spawn helper writes to. Using the git
# common dir means worktrees and the main checkout agree on one location.
STATE_DIR=$(git rev-parse --git-common-dir 2>/dev/null) || {
  echo "[failure] not inside a git work tree"
  exit 1
}
case "$STATE_DIR" in
  /*) ;;
  *)  STATE_DIR="$(git rev-parse --show-toplevel)/$STATE_DIR" ;;
esac

LOG="$STATE_DIR/.agent-review-pr${PR_NUMBER}.log"
PID_FILE="$STATE_DIR/.agent-review-pr${PR_NUMBER}.pid"

# Repo-relative log path for the committed audit shards. The absolute $LOG
# stays in ephemeral stdout (heartbeats are throwaway chat output) but every
# value written to a persistent shard uses $LOG_REL so the audit trail in git
# history never leaks a developer's filesystem layout (PII discipline).
REPO_ROOT="$(dirname "$STATE_DIR")"
LOG_REL="${LOG#"$REPO_ROOT/"}"

# Cross-platform mtime — BSD stat (macOS) and GNU stat differ.
mtime_of() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# Cap echo'd log lines and strip non-printable bytes. The orchestrator's log
# can include diff text influenced by the PR's contents; an attacker-controlled
# diff could embed control characters that scramble the operator's terminal
# when surfaced. Text-only (chars are never executed) but visual hygiene matters.
sanitize_log_line() {
  tr -cd '[:print:]' | cut -c1-160
}

# State-transition audit shard. Coordination primitives must log every
# state change to a PII-free, per-invocation shard (disjoint paths so parallel
# agent branches never conflict at merge). CUSTOMIZE: point at your runlog
# helper; bodies must stay repo-relative — no home-dir absolutes, no email.
RUNLOG="$REPO_ROOT/scripts/runlog.sh"
runlog_state() {
  [ -x "$RUNLOG" ] || return 0
  "$RUNLOG" append agentreview-watch "PR-$PR_NUMBER" "$1" >/dev/null 2>&1 || true
}

# Wait briefly for the spawn to create the log file. Bigger than 5s risks
# masking a spawn that crashed before writing; tighter and a slow spawn under
# load looks identical to a crash.
for _ in 1 2 3 4 5; do
  [ -f "$LOG" ] && break
  sleep 1
done
if [ ! -f "$LOG" ]; then
  echo "[failure] log file did not appear within 5s: $LOG"
  runlog_state "failure | reason=log_not_created | log=$LOG_REL"
  exit 1
fi

REVIEW_PID=""
if [ -f "$PID_FILE" ]; then
  REVIEW_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
  case "$REVIEW_PID" in
    ''|*[!0-9]*) REVIEW_PID="" ;;
  esac
fi

START_TS=$(date +%s)
LAST_HEARTBEAT=$START_TS
# Stall is only meaningful AFTER the log first becomes non-empty. The agent
# CLI is silent-until-completion by design, so a 0-byte log during a healthy
# run is normal. Track the transition so stall counts from "first byte
# written", not "watcher attached".
LOG_FIRST_NONEMPTY_TS=0
echo "[start] pr=$PR_NUMBER pid=${REVIEW_PID:-unknown} log=$LOG heartbeat=${HEARTBEAT_INTERVAL}s stall=${STALL_THRESHOLD}s timeout=${MAX_WAIT}s"
runlog_state "start | pid=${REVIEW_PID:-unknown} | log=$LOG_REL"

# Completion patterns. The orchestrator's stdout (this $LOG) ends with one of
# these on a successful run. CUSTOMIZE these to YOUR /agentreview skill's
# canonical completion line. Note the agent CLI may paraphrase its own summary
# prose run-to-run, so keep each alternation conservative: require a token
# specific to your review skill tied to a `PR #<n>` reference, so a finding
# body that merely quotes "verdict" in passing cannot false-match.
#
# RECOMMENDED hardening (see the source design notes): also poll the
# authoritative artifact — the structured PR comment your /agentreview skill is
# contractually required to post (a stable header + the reviewed HEAD short-SHA
# + a trusted-author allowlist). Key completion off that comment EXISTING, not
# off parsing the LLM-authored verdict label. The free-text grep below misses a
# few percent of genuinely-successful runs; the artifact poll is the robust
# fallback. /ship gates the actual MERGE on that same triple, so it cannot
# drift without breaking the merge gate. Stubbed here to keep the skeleton lean.
VERDICT_PAT='(Agent review (posted|complete) (to|for) PR #[0-9]+|`?/agentreview`? PR #[0-9]+ — Complete|^[[:space:]]*\*{0,2}Verdict:.*(APPROVED|NEEDS CHANGES))'
# Docs-only / no-council short-circuit. Checked BEFORE the verdict branch:
# a skip line can also contain "complete for PR #N" and would otherwise be
# miscounted as a verdict.
SKIPPED_PAT='(SKIPPED \(docs-only\)|`?/agentreview`? (skipped|short-circuited)|^[[:space:]]*\*{0,2}Verdict:.*SKIPPED)'

while :; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TS))

  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    LAST_LINE=$(tail -n 1 "$LOG" 2>/dev/null | sanitize_log_line)
    echo "[timeout] elapsed=${ELAPSED}s threshold=${MAX_WAIT}s last-line='${LAST_LINE}'"
    runlog_state "timeout | elapsed=${ELAPSED}s | log=$LOG_REL"
    exit 1
  fi

  # Log-deletion guard. A cleanup script or operator can remove the log
  # mid-run; without this, mtime_of returns 0 and the stall path fires with
  # the wrong label. Halt-for-human with the right reason instead.
  if [ ! -f "$LOG" ]; then
    echo "[failure] log file disappeared mid-run: $LOG"
    runlog_state "failure | reason=log_deleted | log=$LOG_REL"
    exit 1
  fi

  if [ -s "$LOG" ]; then
    # SKIPPED checked BEFORE VERDICT (a docs-only line can also say "complete
    # for PR #N" and would otherwise miscount as a verdict).
    if SKIP_LINE=$(grep -m1 -E "$SKIPPED_PAT" "$LOG" 2>/dev/null) && [ -n "$SKIP_LINE" ]; then
      SKIP_LINE=$(printf '%s' "$SKIP_LINE" | sanitize_log_line)
      echo "[skipped] $SKIP_LINE"
      runlog_state "skipped | line=$SKIP_LINE"
      exit 0
    fi
    if VERDICT_LINE=$(grep -m1 -E "$VERDICT_PAT" "$LOG" 2>/dev/null) && [ -n "$VERDICT_LINE" ]; then
      VERDICT_LINE=$(printf '%s' "$VERDICT_LINE" | sanitize_log_line)
      echo "[verdict] ${VERDICT_LINE}"
      runlog_state "verdict | line=$VERDICT_LINE"
      exit 0
    fi
  fi

  # CUSTOMIZE: artifact poll goes here — if the log grep above missed, query
  # your tracker/VCS for the orchestrator's structured PR comment (header +
  # reviewed-SHA + trusted author) and exit 0 if it exists. Placed BEFORE the
  # pid-death check so a run that finished (comment posted) but whose pid
  # already exited is recorded as a verdict, not a failure.

  # Process-death detection — pid set AND dead AND no verdict marker above.
  if [ -n "$REVIEW_PID" ] && ! kill -0 "$REVIEW_PID" 2>/dev/null; then
    LAST_LINE=$(tail -n 1 "$LOG" 2>/dev/null | sanitize_log_line)
    echo "[failure] pid=$REVIEW_PID exited without verdict last-line='${LAST_LINE}'"
    runlog_state "failure | reason=pid_dead | pid=$REVIEW_PID | log=$LOG_REL"
    exit 1
  fi

  LOG_MTIME=$(mtime_of "$LOG")
  LOG_AGE=$((NOW - LOG_MTIME))
  LOG_SIZE=$(wc -c <"$LOG" 2>/dev/null | tr -d ' ')

  # Track first-byte-written transition. Once tripped, stall measures idleness
  # from THIS moment forward, not from watcher attach.
  if [ "$LOG_FIRST_NONEMPTY_TS" -eq 0 ] && [ "$LOG_SIZE" -gt 0 ]; then
    LOG_FIRST_NONEMPTY_TS=$NOW
  fi

  # Stall: only count idleness once the orchestrator has written at least one
  # byte (see LOG_FIRST_NONEMPTY_TS above). If we attach to a job whose log was
  # already idle past the threshold, stall fires on the first poll — correct
  # behavior for inheriting a genuinely stuck job.
  if [ "$LOG_FIRST_NONEMPTY_TS" -gt 0 ] && [ "$LOG_AGE" -ge "$STALL_THRESHOLD" ]; then
    echo "[stall] log inactive for ${LOG_AGE}s pid=${REVIEW_PID:-unknown} log=$LOG_REL"
    runlog_state "stall | log_age=${LOG_AGE}s | pid=${REVIEW_PID:-unknown}"
    exit 1
  fi

  if [ "$((NOW - LAST_HEARTBEAT))" -ge "$HEARTBEAT_INTERVAL" ]; then
    echo "[heartbeat] elapsed=${ELAPSED}s pid=${REVIEW_PID:-unknown} log=${LOG_SIZE}B last-mtime=${LOG_AGE}s-ago"
    LAST_HEARTBEAT=$NOW
  fi

  sleep "$POLL_INTERVAL"
done
