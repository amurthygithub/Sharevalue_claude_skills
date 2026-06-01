#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 13-style-multiline-comments.sh — example pre-push rule (the seed rule)
#
# Flags 3+ consecutive newly-added single-line comments attached to a
# non-declaration statement — the "explain every line in prose" anti-pattern.
# Implements your CLAUDE.md comment-style rule (default to one short line;
# multi-line only when the WHY genuinely needs it).
#
# This is the reference rule for the .d/ layout. Copy its shape to add new
# rules: one numeric prefix, one lens (style / security / correctness), a
# self-contained executable, a per-rule WARN→BLOCK switch, and a documented
# PREPUSH_SKIP bypass.
#
# WARN→BLOCK lifecycle (see scripts/pre-push-checks.sh header): a new rule
# ships in WARN mode (always exit 0, just print) and is only promoted to
# BLOCK after a backtest against recent history shows an acceptable
# false-positive rate. The threshold of 3+ (not 2+) and the WARN default
# here were both picked that way — at 2+/BLOCK an early backtest flagged the
# large majority of legitimate commits. Do not flip the default to BLOCK
# without re-running that backtest on YOUR codebase.
#
# Exceptions (the block is allowed):
#   - a `// WHY:` / `# WHY:` / `// NOTE:` / `# NOTE:` annotation inside it, or
#   - a declaration (function / class / decorator / assignment / test-helper)
#     on the line immediately following the block.
#
# Reads PREPUSH_RANGE from the dispatcher (the diff about to be pushed).
# Bypass this one rule:   PREPUSH_SKIP=13-style git push
# Promote to BLOCK:        PREPUSH_MULTILINE_BLOCK=1 git push
#
# Bash 3.2-compatible (works on the default macOS shell).
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

range="${PREPUSH_RANGE:-}"
[ -z "$range" ] && exit 0

# Files in the push with comment-bearing extensions. A while-read loop (not
# mapfile) keeps this portable to bash 3.2; the array keeps multi-word paths
# intact for the diff pathspec.
#
# CUSTOMIZE: adjust the extension allow-list and the build-output / fixture
# exclusions for your stack (e.g. add .go .rb .rs; exclude vendor/, target/).
files=()
while IFS= read -r f; do
  [ -n "$f" ] && files+=("$f")
done < <(git diff --name-only "$range" 2>/dev/null \
  | grep -E '\.(ts|tsx|js|jsx|mjs|py|sh)$' \
  | grep -vE '(^|/)(node_modules|\.next|dist|build|coverage|vendor)/' \
  | grep -vE '(^|/).*\.fixtures?\.' \
  || true)
[ ${#files[@]} -eq 0 ] && exit 0

# Process the unified diff in one awk pass: walk hunks, find runs of 3+
# consecutive `+` comment lines, then inspect the line that follows the run.
# Output is one violation per offending block: "file:lineno: <reason>".
violations=$(git diff -U0 "$range" -- "${files[@]}" | awk '
function is_comment(l,    s) {
  s = l; sub(/^[[:space:]]+/, "", s)
  if (s ~ /^\/\//) return 1      # // line comment
  if (s ~ /^#!/)   return 0      # shebang is not a comment for this rule
  if (s ~ /^#/)    return 1      # # line comment
  return 0
}
function is_declaration(l,    s) {
  s = l; sub(/^[[:space:]]+/, "", s)
  # Control-flow keywords MUST short-circuit before the assignment regex
  # below — otherwise `return x = 1` is mis-read as a declaration and the
  # rule silently stops firing on a comment-before-return block.
  if (s ~ /^(if|elif|else|for|while|return|raise|yield|throw|await|try|except|catch|finally|with|switch|case|default|do|break|continue|pass|new)[[:space:](:]/) return 0
  if (s ~ /^@[A-Za-z_]/) return 1                                   # decorator
  if (s ~ /^(async[[:space:]]+)?def[[:space:]]+/) return 1          # py def
  if (s ~ /^class[[:space:]]+/) return 1                            # class
  if (s ~ /^(export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?(function|class|interface|type|enum)[[:space:]]+/) return 1
  if (s ~ /^(export[[:space:]]+)?(default[[:space:]]+)?(const|let|var)[[:space:]]+[A-Za-z_[{]/) return 1
  if (s ~ /^(import|from)[[:space:]]/) return 1                     # import
  # Identifier-starts assignment (`x =`, `x: T =`, `x[k] =`, `x.attr =`) is
  # the common class-attribute / typed-field shape; without it the rule
  # fires on legit field-level docstrings.
  if (s ~ /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*(\[[^]]*\])?[[:space:]]*[:=]/) return 1
  # CUSTOMIZE: add your test-framework helpers here.
  if (s ~ /^(describe|it|test|beforeAll|beforeEach|afterAll|afterEach)[[:space:]]*\(/) return 1
  if (s == "") return 1          # blank line = paragraph break, treat as decl
  return 0
}
function has_why(arr, n,    i) {
  for (i = 1; i <= n; i++)
    if (arr[i] ~ /(\/\/|#)[[:space:]]*(WHY|NOTE):/) return 1
  return 0
}
function flush(   ) {
  if (run_n >= 3) {
    # Fail-OPEN on incomplete info: only fire when the FOLLOWING line is
    # actually present in the diff to inspect (next_added != ""). A
    # comment-only hunk tail is conservatively allowed.
    if (next_added != "" && !is_declaration(next_added) && !has_why(run, run_n)) {
      printf("%s:%d: %d consecutive new comment lines attached to a non-declaration target\n", \
             file, run_start, run_n)
    }
  }
  run_n = 0; next_added = ""
}
/^diff --git/ {
  flush()
  match($0, /b\/[^ ]+$/)
  file = (RSTART > 0) ? substr($0, RSTART + 2) : "?"
  in_hunk = 0; next
}
/^@@/ {
  flush()
  new_lineno = (match($0, /\+[0-9]+/)) ? substr($0, RSTART + 1, RLENGTH - 1) + 0 : 0
  in_hunk = 1; next
}
in_hunk == 0 { next }
/^\\ No newline/ { next }
{
  ch = substr($0, 1, 1); body = substr($0, 2)
  if (ch == "+") {
    if (is_comment(body)) {
      if (run_n == 0) run_start = new_lineno
      run_n++; run[run_n] = body
    } else {
      if (run_n >= 3) next_added = body   # the attached statement
      flush()
    }
    new_lineno++
  } else if (ch == " ") {                 # context line = attached statement
    if (run_n >= 3 && !is_comment(body)) next_added = body
    flush(); new_lineno++
  } else if (ch == "-") {                 # deletion: flush, do not advance
    flush()
  }
}
END { flush() }
')

if [ -n "$violations" ]; then
  # Per-rule WARN→BLOCK switch. WARN (exit 0) by default; set
  # PREPUSH_MULTILINE_BLOCK=1 to promote to BLOCK locally. Flip the default
  # only after backtesting the false-positive rate on your own history.
  if [ "${PREPUSH_MULTILINE_BLOCK:-0}" = "1" ]; then
    label="FAIL"; rc=1
  else
    label="WARN"; rc=0
  fi
  echo "[pre-push-checks] 13-style-multiline-comments: $label"
  echo
  echo "  Default to one short comment line; multi-line only when the WHY"
  echo "  genuinely needs it. These blocks are 3+ consecutive new comment"
  echo "  lines attached to non-declaration targets:"
  echo
  printf '    %s\n' "${violations//$'\n'/$'\n    '}"
  echo
  echo "  Fixes:"
  echo "    1. Trim the comment to one line."
  echo "    2. Add // WHY: <reason>  or  # WHY: <reason>  to justify the block."
  echo "    3. PREPUSH_SKIP=13-style git push     # bypass this one rule."
  exit $rc
fi

exit 0
