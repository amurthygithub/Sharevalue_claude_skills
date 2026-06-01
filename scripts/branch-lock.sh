#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# branch-lock.sh — per-branch ownership lock for /work-on and /ship (template)
#
# Push interlock for parallel-agent safety. When many agent sessions share one
# machine (each in its own `git worktree`), two grabbing the same branch and
# racing to push corrupts each other's work. /work-on claims a branch; /ship
# refuses to push when another live session owns it.
#
# Scope (read before adapting):
#   - Per-MACHINE: coordinates sessions on one laptop; cannot arbitrate
#     cross-machine collisions — use your <TRACKER> status for that.
#   - PUSH-time only: editing files in a worktree is never gated (nothing in the
#     filesystem can stop another agent typing). The lock gates the push, where
#     the real conflict lands.
#
# Ownership identity is the **worktree path**, NOT the PID. Each subcommand runs
# in a short-lived subshell whose PID dies on return, so a PID-keyed lock would
# auto-stale instantly. The worktree path is stable for the session's life:
# /work-on and /ship in the same worktree see the same
# `git rev-parse --show-toplevel`; two agents in DIFFERENT worktrees are
# correctly distinguished.
#
# Subcommands:
#   acquire <branch> <ticket> [worktree-path]
#       Create lock. Exit 0 on success (or already-owned). Exit 1 on live
#       conflict (prints conflicting lock JSON to STDERR). Auto-releases a
#       stale lock first.
#   verify <branch>
#       Exit 0 if unlocked or owned by this worktree; exit 1 if owned by another
#       live session. Auto-releases stale locks.
#   release <branch>
#       Remove the lock if owned by this worktree. Logged no-op otherwise.
#   cleanup-stale
#       Bulk-remove every stale lock.
#   takeover <branch> --reason "..."
#       Forcibly release + re-acquire. Refuses if the lock is still live, or if
#       upstream has advanced past the holder's recorded HEAD (their unpushed
#       work would be orphaned).
#
# Lock file: $GIT_COMMON_DIR/branch-locks/<sanitized-branch>.json
#   { pid, agent_session_id, git_user_email, ticket_id, branch_name,
#     worktree_path, acquired_at, acquired_at_local_head }
#   `pid` is audit-only — ownership is by worktree_path.
#
# Auto-stale signals (a lock is reclaimable when EITHER holds):
#   1. The recorded worktree no longer exists on disk (session ended).
#   2. The lock is older than $STALE_AGE_SECONDS (24h default).
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

STALE_AGE_SECONDS="${BRANCH_LOCK_STALE_AGE:-86400}"

usage() {
  cat >&2 <<'USAGE'
branch-lock.sh — per-branch ownership lock (ownership by worktree path, not PID)
  acquire <branch> <ticket> [worktree-path]
  verify <branch>
  release <branch>
  cleanup-stale
  takeover <branch> --reason "..."
USAGE
  exit 2
}

# ── Path helpers ─────────────────────────────────────────────────────────────
# $GIT_COMMON_DIR is shared by all worktrees of one repo, so the lock dir is a
# single rendezvous point every session can see.
git_common_dir() {
  local d
  d=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$d" in
    /*) printf '%s\n' "$d" ;;
    *)  printf '%s/%s\n' "$(git rev-parse --show-toplevel)" "$d" ;;
  esac
}
lock_dir()  { printf '%s/branch-locks\n' "$(git_common_dir)"; }
sanitize_branch() { printf '%s' "$1" | tr '/' '_' | tr -c 'A-Za-z0-9._-' '_' | sed 's/__*/_/g; s/^_//; s/_$//'; }
lock_path() { printf '%s/%s.json\n' "$(lock_dir)" "$(sanitize_branch "$1")"; }
current_worktree() { git rev-parse --show-toplevel 2>/dev/null; }
upstream_exists()  { git ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1; }

# ── Audit trail ──────────────────────────────────────────────────────────────
# State-transition logging is a hard requirement for any coordination primitive
# other agents gate on: post-incident "why was X locked at 2am?" needs a
# timeline, not just a snapshot. Emit on EVERY transition: acquire / release /
# conflict-refused / takeover / cleanup, plus a *-skipped variant for no-ops
# (e.g. a non-owner asking to release) so misconfigured callers surface.
#
# CUSTOMIZE: point this at your own append-only audit-shard helper. The shape:
# one file per invocation under a date-sharded dir (avoids merge conflicts
# between parallel sessions) rather than appending to one shared log. Failure
# here is non-fatal — lock semantics never depend on the audit write landing.
emit_runlog_event() {
  local state="${1:-unknown}" ticket="${2:--}" body="${3:-}"
  local top runlog
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  runlog="$top/scripts/runlog.sh"          # CUSTOMIZE: your audit helper
  [[ -x "$runlog" ]] || return 0
  "$runlog" append "branch-lock-$state" "$ticket" "$body" >/dev/null 2>&1 || true
}

# Canonicalize a path for the audit shard: strip the repo prefix so worktrees
# log as `.worktrees/feature-x` instead of a developer's home-dir absolute.
# Shards are committed to git history — keep them PII-free (no emails, no
# /home/<user>/ paths).
worktree_for_log() {
  local path="${1:-}" gcd repo_root
  [[ -z "$path" || "$path" == "?" ]] && { printf '%s' "$path"; return; }
  gcd=$(git rev-parse --git-common-dir 2>/dev/null) || { printf '%s' "$path"; return; }
  case "$gcd" in /*) ;; *) gcd="$(git rev-parse --show-toplevel 2>/dev/null)/$gcd" ;; esac
  repo_root=$(cd "$(dirname "$gcd")" 2>/dev/null && pwd) || { printf '%s' "$path"; return; }
  case "$path" in
    "$repo_root")   printf '.' ;;
    "$repo_root"/*) printf '%s' "${path#"$repo_root"/}" ;;
    *)              printf '%s' "$path" ;;
  esac
}

# ── Staleness ────────────────────────────────────────────────────────────────
# Fallback to epoch 0 on an unparseable timestamp so a corrupt lock looks
# maximally stale (age >> 24h → auto-released) rather than wedging forever.
epoch_of_iso() {
  local iso="$1"
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null \
    || date -u -d "$iso" +%s 2>/dev/null \
    || echo 0
}

worktree_owns() {
  local lock_worktree="${1:-}" mine
  mine=$(current_worktree)
  [[ -n "$lock_worktree" && -n "$mine" && "$lock_worktree" == "$mine" ]]
}

# Human-readable reason, mirroring the branches in is_stale().
stale_reason() {
  local lock="$1" worktree acquired
  worktree=$(jq -r '.worktree_path // empty' "$lock" 2>/dev/null || echo "")
  acquired=$(jq -r '.acquired_at // empty' "$lock" 2>/dev/null || echo "")
  [[ -z "$worktree" && -z "$acquired" ]] && { echo "corrupt"; return; }
  [[ -n "$worktree" && ! -d "$worktree" ]] && { echo "worktree-gone"; return; }
  echo "aged"
}

is_stale() {
  local lock="$1" worktree acquired
  [[ -f "$lock" ]] || return 1
  worktree=$(jq -r '.worktree_path // empty' "$lock" 2>/dev/null || echo "")
  acquired=$(jq -r '.acquired_at // empty' "$lock" 2>/dev/null || echo "")
  # A hand-corrupted lock with neither field is unrecoverable by normal checks;
  # treat as stale to avoid an immortal lock only `rm` could clear.
  [[ -z "$worktree" && -z "$acquired" ]] && return 0
  [[ -n "$worktree" && ! -d "$worktree" ]] && return 0
  if [[ -n "$acquired" ]]; then
    local age=$(( $(date +%s) - $(epoch_of_iso "$acquired") ))
    [[ "$age" -ge "$STALE_AGE_SECONDS" ]] && return 0
  fi
  return 1
}

# ── acquire ──────────────────────────────────────────────────────────────────
cmd_acquire() {
  local branch="${1:-}" ticket="${2:-}" worktree_path="${3:-$(pwd)}"
  [[ -z "$branch" || -z "$ticket" ]] && { echo "acquire: requires <branch> <ticket>" >&2; return 2; }
  [[ "$worktree_path" != /* ]] && worktree_path="$(cd "$worktree_path" 2>/dev/null && pwd)" || true

  local dir lock
  dir=$(lock_dir); mkdir -p "$dir"; lock=$(lock_path "$branch")

  if [[ -f "$lock" ]]; then
    if is_stale "$lock"; then
      local pr_ticket pr_wt pr_reason
      pr_ticket=$(jq -r '.ticket_id // "-"' "$lock" 2>/dev/null)
      pr_wt=$(jq -r '.worktree_path // "?"' "$lock" 2>/dev/null)
      pr_reason=$(stale_reason "$lock")
      rm -f "$lock"
      emit_runlog_event cleanup "$pr_ticket" "branch=$branch reason=$pr_reason prev_worktree=$(worktree_for_log "$pr_wt") trigger=acquire"
    else
      local owner; owner=$(jq -r '.worktree_path // empty' "$lock" 2>/dev/null)
      worktree_owns "$owner" && return 0        # idempotent re-acquire
      emit_runlog_event conflict-refused "$ticket" \
        "branch=$branch mine=$(worktree_for_log "$worktree_path") holder=$(worktree_for_log "$owner")"
      cat "$lock" >&2                            # conflict JSON → stderr; stdout reserved for success
      return 1
    fi
  fi

  local now email session head_sha payload
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  email=$(git config user.email 2>/dev/null || echo "unknown@local")
  session="${AGENT_SESSION_ID:-$(hostname)-$$-$(date +%s)}"   # CUSTOMIZE: your agent's session-id env var
  head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
  payload=$(jq -n --argjson pid "$$" --arg session "$session" --arg email "$email" \
    --arg ticket "$ticket" --arg branch "$branch" --arg worktree "$worktree_path" \
    --arg acquired "$now" --arg head_sha "$head_sha" \
    '{pid:$pid, agent_session_id:$session, git_user_email:$email, ticket_id:$ticket,
      branch_name:$branch, worktree_path:$worktree, acquired_at:$acquired,
      acquired_at_local_head:$head_sha}')

  # Atomic create-exclusive via noclobber (`set -C`). Closes the TOCTOU gap
  # between the existence check above and this write: if a racing acquire snuck
  # a file in, the redirect fails — re-read it and emit a conflict.
  if ! ( set -C; printf '%s\n' "$payload" > "$lock" ) 2>/dev/null; then
    if [[ -f "$lock" ]]; then
      local owner; owner=$(jq -r '.worktree_path // empty' "$lock" 2>/dev/null)
      worktree_owns "$owner" && return 0
      emit_runlog_event conflict-refused "$ticket" \
        "branch=$branch mine=$(worktree_for_log "$worktree_path") holder=$(worktree_for_log "$owner") race=noclobber"
      cat "$lock" >&2
    fi
    return 1
  fi

  emit_runlog_event acquire "$ticket" \
    "branch=$branch worktree=$(worktree_for_log "$worktree_path") head=${head_sha:0:7}"
}

# ── verify ───────────────────────────────────────────────────────────────────
cmd_verify() {
  local branch="${1:-}"
  [[ -z "$branch" ]] && { echo "verify: requires <branch>" >&2; return 2; }
  local lock; lock=$(lock_path "$branch")
  [[ -f "$lock" ]] || return 0

  if is_stale "$lock"; then
    local t w; t=$(jq -r '.ticket_id // "-"' "$lock" 2>/dev/null); w=$(jq -r '.worktree_path // "?"' "$lock" 2>/dev/null)
    rm -f "$lock"
    emit_runlog_event cleanup "$t" "branch=$branch reason=$(stale_reason "$lock") prev_worktree=$(worktree_for_log "$w") trigger=verify"
    return 0
  fi
  local owner; owner=$(jq -r '.worktree_path // empty' "$lock" 2>/dev/null)
  worktree_owns "$owner" && return 0
  cat "$lock" >&2
  return 1
}

# ── release ──────────────────────────────────────────────────────────────────
cmd_release() {
  local branch="${1:-}"
  [[ -z "$branch" ]] && { echo "release: requires <branch>" >&2; return 2; }
  local lock; lock=$(lock_path "$branch")
  [[ -f "$lock" ]] || return 0

  local owner; owner=$(jq -r '.worktree_path // empty' "$lock" 2>/dev/null)
  if worktree_owns "$owner"; then
    local t a; t=$(jq -r '.ticket_id // "-"' "$lock" 2>/dev/null); a=$(jq -r '.acquired_at // "?"' "$lock" 2>/dev/null)
    rm -f "$lock"
    emit_runlog_event release "$t" "branch=$branch worktree=$(worktree_for_log "$owner") acquired_at=$a"
    return 0
  fi
  if is_stale "$lock"; then
    local t w; t=$(jq -r '.ticket_id // "-"' "$lock" 2>/dev/null); w=$(jq -r '.worktree_path // "?"' "$lock" 2>/dev/null)
    rm -f "$lock"
    emit_runlog_event cleanup "$t" "branch=$branch reason=$(stale_reason "$lock") prev_worktree=$(worktree_for_log "$w") trigger=release"
    return 0
  fi
  # Non-owner no-op: state unchanged, but the attempt is audit-worthy — it
  # surfaces a misconfigured caller or a coordination bug.
  local t; t=$(jq -r '.ticket_id // "-"' "$lock" 2>/dev/null)
  emit_runlog_event release-skipped "$t" \
    "branch=$branch reason=not-owner mine=$(worktree_for_log "$(current_worktree)") holder=$(worktree_for_log "$owner")"
  echo "🛈 Lock on $branch held by another worktree; not releasing" >&2
  return 0
}

# ── cleanup-stale ────────────────────────────────────────────────────────────
cmd_cleanup_stale() {
  local dir; dir=$(lock_dir)
  [[ -d "$dir" ]] || { echo "🧹 Removed 0 stale lock(s)"; return 0; }
  local removed=0
  shopt -s nullglob
  for lock in "$dir"/*.json; do
    if is_stale "$lock"; then
      local b t w; b=$(jq -r '.branch_name // "-"' "$lock" 2>/dev/null)
      t=$(jq -r '.ticket_id // "-"' "$lock" 2>/dev/null); w=$(jq -r '.worktree_path // "?"' "$lock" 2>/dev/null)
      emit_runlog_event cleanup "$t" "branch=$b reason=$(stale_reason "$lock") prev_worktree=$(worktree_for_log "$w") trigger=cleanup-stale"
      rm -f "$lock"; removed=$((removed + 1))
    fi
  done
  shopt -u nullglob
  echo "🧹 Removed $removed stale lock(s)"
}

# ── takeover ─────────────────────────────────────────────────────────────────
# Manual recovery for a genuinely-wedged lock. Two refusals are load-bearing:
# (1) won't steal a still-live lock — two live sessions cannot share a branch;
# (2) won't steal if upstream advanced past the holder's recorded HEAD, since
#     their unpushed commits would be orphaned.
cmd_takeover() {
  local branch="${1:-}"; shift || true
  local reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason) reason="${2:-}"; shift 2 || true ;;
      *) echo "takeover: unknown flag '$1'" >&2; return 2 ;;
    esac
  done
  [[ -z "$branch" || -z "$reason" ]] && { echo "takeover: requires <branch> --reason \"...\"" >&2; return 2; }

  local lock; lock=$(lock_path "$branch")
  [[ -f "$lock" ]] || { echo "❌ No lock on $branch — use 'acquire' instead." >&2; return 1; }

  local wt acquired email head ticket
  wt=$(jq -r '.worktree_path // empty' "$lock" 2>/dev/null)
  acquired=$(jq -r '.acquired_at // empty' "$lock" 2>/dev/null)
  email=$(jq -r '.git_user_email // "unknown"' "$lock" 2>/dev/null)
  head=$(jq -r '.acquired_at_local_head // empty' "$lock" 2>/dev/null)
  ticket=$(jq -r '.ticket_id // "unknown"' "$lock" 2>/dev/null)

  local age=$(( $(date +%s) - $(epoch_of_iso "$acquired") ))
  local live=0; [[ -n "$wt" && -d "$wt" ]] && live=1

  # Refusal 1 — still live and recent.
  if [[ "$live" == "1" && "$age" -lt "$STALE_AGE_SECONDS" ]]; then
    echo "❌ Refusing takeover — lock is live and recent (held by $email, age $((age/60))m)." >&2
    echo "   Open a sibling branch, or wait for the other session to /ship." >&2
    return 1
  fi

  # Refusal 2 — upstream advanced past the holder's recorded HEAD.
  if upstream_exists "$branch" && [[ -n "$head" ]]; then
    git fetch origin "$branch" --quiet 2>/dev/null || true
    local up; up=$(git rev-parse "origin/$branch" 2>/dev/null || echo "")
    if [[ -n "$up" && "$up" != "$head" ]] && ! git merge-base --is-ancestor "$up" "$head" 2>/dev/null; then
      echo "⚠️  Refusing takeover — origin/$branch advanced past acquirer's HEAD (${head:0:7} vs ${up:0:7})." >&2
      echo "    Their work would be orphaned. Rebase on origin/$branch, or open a sibling branch." >&2
      return 1
    fi
  fi

  local snapshot; snapshot=$(cat "$lock")
  echo "🔓 Taking over lock on $branch (was $email) — reason: $reason"

  # Guard the post-rm acquire: if a racing acquire wins the noclobber, the old
  # lock is gone and the branch would be silently unprotected. Surface it.
  rm -f "$lock"
  if ! cmd_acquire "$branch" "$ticket" "$(pwd)"; then
    echo "❌ takeover acquire failed — branch $branch is now UNLOCKED (racing acquire?)." >&2
    return 1
  fi

  # Stamp the takeover provenance onto the new lock.
  local new_lock now_iso merged
  new_lock=$(lock_path "$branch"); now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  merged=$(jq --argjson prev "$snapshot" --arg reason "$reason" --arg now "$now_iso" \
    '. + {takeover_reason:$reason, takeover_at:$now, previous_holder:$prev}' "$new_lock")
  printf '%s\n' "$merged" > "$new_lock"

  emit_runlog_event takeover "$ticket" \
    "branch=$branch prev_worktree=$(worktree_for_log "$wt") reason=\"$reason\""
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    acquire)       cmd_acquire "$@" ;;
    verify)        cmd_verify "$@" ;;
    release)       cmd_release "$@" ;;
    cleanup-stale) cmd_cleanup_stale "$@" ;;
    takeover)      cmd_takeover "$@" ;;
    -h|--help|help|"") usage ;;
    *) echo "branch-lock.sh: unknown subcommand: $sub" >&2; usage ;;
  esac
}

main "$@"
