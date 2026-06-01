#!/usr/bin/env bash
# Canonical danger-zone path regex + scan helpers.
#
# Single source of truth for the privileged-path set whose modification
# must NOT be auto-merged on an agent verdict alone. Source this from
# /ship, /agentreview, /promote, and any future consumer rather than
# inlining the regex in each skill — the inline-copy pattern requires
# N-way lockstep updates and was a recurring source of review-iteration
# findings in an earlier version of these skills.
#
# Consumer pattern:
#   . "$(git rev-parse --show-toplevel)/scripts/danger-zone-scan.sh"
#   DANGER_HITS=$(danger_zone_scan)              # origin/staging...HEAD (3-dot)
#   DANGER_HITS=$(danger_zone_scan_full)         # union (commit-time semantics)
#   DANGER_HITS=$(echo "$FILES" | danger_zone_filter_paths)  # PR-API input

# This file is sourced, not executed. Re-sourcing is idempotent — the
# guard below no-ops on second and later sources. `return` requires
# sourced context, so running this directly (`./danger-zone-scan.sh`)
# errors here, which is intended: it is a library, not a command.
if [ -n "${_DANGER_ZONE_SCAN_LOADED:-}" ]; then
  return 0
fi
_DANGER_ZONE_SCAN_LOADED=1

# CUSTOMIZE: this regex is the source of truth for "danger zone" path
# checks. Keep it in sync with the <DANGER_PATHS_REGEX> placeholder in
# CLAUDE.md §9.2 and .claude/skills/ship/SKILL.md (Steps 3 and 8). Add
# the paths your project must protect; remove the ones that don't apply.
#
# POSIX extended regex, anchored at the start of the path. Update HERE
# and every consumer picks up the change on its next source. Categories
# that apply to almost everyone:
#   - migration files (immutable post-merge)
#   - ORM/model definitions (schema changes need migration review)
#   - .env files (any environment)
#   - CI workflow definitions (broken gates affect every PR)
#   - CI/infra scripts (branch protection, this gate itself)
#   - deploy/host vendor config
#   - the agent surfaces that inherit to every future session:
#     .claude/settings.json, skills/, agents/, and CLAUDE.md
DANGER_PATHS='^(<BACKEND_DIR>/migrations/versions/|<BACKEND_DIR>/.*/db/models/|\.env($|\.|/)|\.github/workflows/|scripts/(install-branch-protection\.sh|ci-local\.sh|danger-zone-scan\.sh)|<FRONTEND_DIR>/<HOST_VENDOR_CONFIG>|\.claude/(settings\.json|skills/|agents/)|CLAUDE\.md$)'

# Verify the staging remote is reachable before relying on `git diff`
# against it. Without this guard, a missing/renamed remote silently
# produces empty diff output that downstream greps read as "no hits" —
# a fail-OPEN in a gate whose whole job is to be bypass-resistant.
#
# Returns 0 if reachable, 1 + stderr message if not. The caller converts
# that into a halt or fall-back per its own contract; most callers MUST
# fail-closed. Surfacing this as an explicit function lets each caller
# make that choice deliberately rather than inherit a silent failure.
danger_zone_require_remote() {
  git ls-remote --exit-code origin staging >/dev/null 2>&1 || {
    echo "danger-zone-scan: origin/staging unreachable — gate aborted" >&2
    echo "   Run \`git fetch origin staging\` or check your remote config." >&2
    return 1
  }
}

# Scan the diff between two refs (default: origin/staging...HEAD, 3-dot
# merge-base form) and print matching privileged paths on stdout. Empty
# stdout = no hits. Returns 1 if the remote precheck fails — callers MUST
# treat that distinctly from "0 hits"; a stale-remote run is not a clean
# diff.
#
# 3-dot vs 2-dot: `A...B` shows only what B adds on top of the shared
# ancestor — exactly what the gate wants ("what is THIS branch adding?").
# The 2-dot form `A B` does a tip-vs-tip diff and false-fires whenever
# the local branch is behind upstream. The PR review surface uses 3-dot
# for the same reason, so this keeps the merge-time gate aligned with
# what the reviewer actually reviewed.
#
# Usage:
#   DANGER_HITS=$(danger_zone_scan) || halt_with_remote_error
#   DANGER_HITS=$(danger_zone_scan origin/main HEAD) || halt_with_remote_error
danger_zone_scan() {
  local base="${1:-origin/staging}" head="${2:-HEAD}"
  danger_zone_require_remote || return 1
  git diff --name-only "$base"..."$head" 2>/dev/null \
    | grep -E "$DANGER_PATHS" || true
}

# Commit-time semantics: union of pushed (origin/staging...HEAD, 3-dot)
# + unstaged + staged. Used before push, when origin/staging may not yet
# contain the local commits but staged/unstaged content still needs the
# check. Same remote-precheck contract as danger_zone_scan.
danger_zone_scan_full() {
  danger_zone_require_remote || return 1
  {
    git diff --name-only origin/staging...HEAD 2>/dev/null
    git diff --name-only HEAD
    git diff --name-only --cached
  } | sort -u | grep -E "$DANGER_PATHS" || true
}

# Filter a list of paths from stdin, returning only the danger-zone hits.
# Used when paths come from an external source (PR API, find, etc.)
# rather than git diff — no remote precheck needed, the caller already
# holds the paths.
#
# Usage:
#   DANGER_HITS=$(echo "$FILES" | danger_zone_filter_paths)
danger_zone_filter_paths() {
  grep -E "$DANGER_PATHS" || true
}
