#!/usr/bin/env bash
# runlog.sh — per-invocation shard logger for agent skills.
#
# WHY this exists: many agent sessions run in parallel (separate worktrees /
# branches). If every skill appended `>>` to one shared RUN_LOG.md, those
# branches would conflict on the same lines at merge time. Instead, each
# invocation writes ONE small file at a UNIQUE path under
# docs/agent-evolution/runs/<UTC-date>/. Disjoint paths = git merges every
# branch's audit trail cleanly. Any legacy single-file RUN_LOG.md is frozen
# as a read-only archive; new entries only go through this helper.
#
# Subcommands:
#   append <skill> <ticket-or-dash> <body>
#       Write one audit line to a uniquely-named shard.
#       Output line: "<ISO UTC> | /<skill> <ticket> | <body>".
#       <ticket> may be "-" to omit. <body> is free-form, typically a
#       pipe-delimited "<outcome> | key=value | key=value" string.
#   view  [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--ticket TICKET-NNN] [--skill NAME]
#       Print every shard line in chronological order (substring filters).
#   index [--out PATH]
#       Regenerate a human-readable chronological index of all shards.
#
# PII / portability discipline (load-bearing): shard bodies are committed to
# git history. Callers MUST keep them PII-free — repo-relative paths only, no
# developer email, no home-dir absolutes. This helper does not enforce that;
# the convention lives at the call site (see CLAUDE.md's coordination-logging
# rule). Filenames embed a UTC timestamp so `find … | sort` is chronological,
# plus a random suffix so two invocations in the same second don't collide.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
RUNS_DIR="${RUNLOG_DIR:-$REPO_ROOT/docs/agent-evolution/runs}"

usage() {
  sed -n '2,30p' "$0"
  exit 2
}

# Strip everything outside [A-Za-z0-9_-] so a skill/ticket token is filename-safe.
sanitize() {
  local s="$1"
  printf '%s' "${s//[^A-Za-z0-9_-]/}"
}

# 6-char random suffix; /dev/urandom is portable across macOS + Linux.
randstr() {
  LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 6
  printf '\n'
}

cmd_append() {
  local skill="${1:-}" ticket="${2:-}" body="${3:-}"
  if [[ -z "$skill" || -z "$ticket" || -z "$body" ]]; then
    echo "runlog.sh append: missing argument" >&2
    echo "usage: runlog.sh append <skill> <ticket-or-dash> <body>" >&2
    return 2
  fi

  local now_iso date_dir hms rand skill_safe ticket_safe
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  date_dir=$(date -u +%Y-%m-%d)
  hms=$(date -u +%H%M%S)
  rand=$(randstr)
  skill_safe=$(sanitize "$skill")
  ticket_safe=$(sanitize "$ticket")
  [[ -z "$ticket_safe" ]] && ticket_safe="-"

  mkdir -p "$RUNS_DIR/$date_dir"
  local out_path="$RUNS_DIR/$date_dir/${hms}Z-${skill_safe}-${ticket_safe}-${rand}.log"

  local prefix
  if [[ "$ticket" == "-" || -z "$ticket" ]]; then
    prefix="$now_iso | /$skill |"
  else
    prefix="$now_iso | /$skill $ticket |"
  fi

  printf '%s %s\n' "$prefix" "$body" > "$out_path"
  printf '%s\n' "$out_path"
}

cmd_view() {
  local since="" until="" ticket="" skill=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since)  since="$2";  shift 2 ;;
      --until)  until="$2";  shift 2 ;;
      --ticket) ticket="$2"; shift 2 ;;
      --skill)  skill="$2";  shift 2 ;;
      *) echo "unknown flag: $1" >&2; return 2 ;;
    esac
  done

  [[ -d "$RUNS_DIR" ]] || return 0

  # Filenames begin with the date dir + HHMMSSZ, so `sort` is chronological.
  while IFS= read -r f; do
    local rel="${f#"$RUNS_DIR"/}" d
    d="${rel%%/*}"
    [[ -n "$since" && "$d" < "$since" ]] && continue
    [[ -n "$until" && "$d" > "$until" ]] && continue
    [[ -n "$ticket" ]] && { grep -q -F "$ticket" "$f" || continue; }
    [[ -n "$skill"  ]] && { grep -q -E "/${skill}( |\|)" "$f" || continue; }
    cat "$f"
  done < <(find "$RUNS_DIR" -type f -name '*.log' 2>/dev/null | sort)
}

cmd_index() {
  local out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      *) echo "unknown flag: $1" >&2; return 2 ;;
    esac
  done

  local header body now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # CUSTOMIZE: adjust the regenerated-header prose / path to your repo layout.
  # shellcheck disable=SC2016  # backticks here are literal markdown.
  header=$(printf '# RUN_LOG (regenerated)\n\nGenerated: %s\nSource: docs/agent-evolution/runs/\n\nDo not edit by hand. Run `scripts/runlog.sh index --out docs/agent-evolution/RUN_LOG.md` to refresh.\n\n---\n' "$now")
  body=$(cmd_view)

  if [[ -n "$out" ]]; then
    { printf '%s\n\n' "$header"; printf '%s\n' "$body"; } > "$out"
    printf 'wrote %s\n' "$out"
  else
    printf '%s\n\n' "$header"
    printf '%s\n' "$body"
  fi
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    append) cmd_append "$@" ;;
    view)   cmd_view   "$@" ;;
    index)  cmd_index  "$@" ;;
    -h|--help|help|"") usage ;;
    *) echo "runlog.sh: unknown subcommand: $sub" >&2; usage ;;
  esac
}

main "$@"
