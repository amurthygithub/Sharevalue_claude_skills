#!/usr/bin/env bash
# 21-security-secret-echo.sh — flag newly-added shell that writes a
# secret-shaped variable to stdout (template).
#
# WHY: a real incident class in our repo — repeated credential rotations
# all traced to a variant of `echo "$DATABASE_URL"` slipping into a
# script, log line, or transcript. The rule is purely mechanical (regex
# over the push diff) so it catches the new-additions case at push time.
# Existing offenders already merged are out of scope — this is a ratchet
# on NEW lines only.
#
# Ships in WARN mode (exit 0, print only). Promote to BLOCK locally with
# PREPUSH_SECRET_ECHO_BLOCK=1 only after a backtest against recent
# history shows an acceptable false-positive rate — see the WARN→BLOCK
# lifecycle note in pre-push-checks.sh.
#
# Bypass one push:  PREPUSH_SKIP=21-security git push
# Promote to BLOCK: PREPUSH_SECRET_ECHO_BLOCK=1 git push
#
# Scope: `.sh` files and anything under scripts/, EXCLUDING test dirs
# (fixtures must contain positive-case patterns to validate this rule and
# would otherwise self-flag on every push).
#
# Secret-shaped names (case-sensitive uppercase): DATABASE_URL plus any
# `*_KEY / *_TOKEN / *_SECRET / *_PASSWORD / *_API_KEY / *_CREDENTIAL /
# *_PRIVATE_KEY`. The suffix is anchored at end-of-name so a path-suffix
# variable like SOME_PRIVATE_KEY_PATH does NOT false-positive on the
# embedded PRIVATE_KEY substring.
#
# Fires on a newly-added (`+`) line when a secret-shaped var appears in:
#   1. echo / printf / cat — and the secret ref comes AFTER the keyword
#      (so `[ -n "$API_KEY" ] && echo ok` does NOT fire on co-occurrence).
#   2. `head -c N` near a secret-shaped var (truncate-to-display form).
#   3. substring expansion `${VAR:N}` / `${VAR:N:M}` (display of a prefix).
#
# Allowed (does NOT fire): `${#VAR}` length, boolean comparison
# (`[ "$A" = "$B" ]`), assignment / export, and comment lines.
#
# NOTE: the awk comments below live inside a single-quoted bash block.
# Avoid apostrophes in that scope to keep the bash parser happy.
set -uo pipefail

# PREPUSH_RANGE is exported by the pre-push-checks.sh dispatcher.
range="${PREPUSH_RANGE:-}"
[ -z "$range" ] && exit 0

# In-scope files: `.sh` OR anywhere under scripts/, minus test fixtures.
# CUSTOMIZE: add languages/dirs your project ships secrets-handling code in.
files=()
while IFS= read -r f; do
  [ -n "$f" ] && files+=("$f")
done < <(git diff --name-only "$range" 2>/dev/null \
  | grep -E '(^scripts/|\.sh$)' \
  | grep -vE '^scripts/tests/|^scripts/pre-push-checks\.d/tests/' \
  || true)
[ ${#files[@]} -eq 0 ] && exit 0

# Walk the unified diff. For each newly-added line, apply the detection
# algorithm and emit `<file>|<lineno>|<reason>|<body>` to stdout.
candidates=$(git diff -U0 "$range" -- "${files[@]}" 2>/dev/null | awk '
function trim(s) {
  sub(/^[[:space:]]+/, "", s)
  sub(/[[:space:]]+$/, "", s)
  return s
}

# Secret-shaped variable regex (POSIX ERE). Anchors the suffix at the end
# of the name token so SOME_PRIVATE_KEY_PATH does not false-positive on
# the embedded PRIVATE_KEY. Returns the 1-based position of the FIRST
# secret reference, or 0. Position lets callers gate on "keyword appears
# AFTER secret" to suppress same-line co-occurrence false positives.
function secret_ref_pos(line,    p) {
  if (match(line, /\$\{?(DATABASE_URL|[A-Z][A-Z0-9_]*_(KEY|TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|CREDENTIAL|CREDENTIALS|PRIVATE_KEY))([^A-Z0-9_]|$)/)) {
    p = RSTART
    return p
  }
  return 0
}

/^diff --git/ {
  match($0, /b\/[^ ]+$/)
  if (RSTART > 0) { file = substr($0, RSTART + 2) } else { file = "?" }
  in_hunk = 0
  next
}
/^@@/ {
  if (match($0, /\+[0-9]+/)) {
    new_lineno = substr($0, RSTART + 1, RLENGTH - 1) + 0
  } else {
    new_lineno = 0
  }
  in_hunk = 1
  next
}
in_hunk == 0 { next }
/^\\ No newline/ { next }
{
  ch = substr($0, 1, 1)
  body = substr($0, 2)
  if (ch == "+") {
    stripped = trim(body)

    # Comment line — skip.
    if (substr(stripped, 1, 1) == "#") { new_lineno++; next }

    # Substring expansion of a secret-shaped var: ${VAR:N} or ${VAR:N:M}.
    if (body ~ /\$\{(DATABASE_URL|[A-Z][A-Z0-9_]*_(KEY|TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|CREDENTIAL|CREDENTIALS|PRIVATE_KEY)):[0-9-]/) {
      print file "|" new_lineno "|substring-expansion|" body
      new_lineno++
      next
    }

    # Output-producing keyword + secret ref AFTER the keyword. cat is
    # included because `cat <<<"$VAR"` writes the secret like echo does.
    kw_pos = 0
    keyword = ""
    if (match(body, /(^|[^[:alnum:]_])echo([[:space:]]|$)/)) { kw_pos = RSTART + RLENGTH - 1; keyword = "echo" }
    else if (match(body, /(^|[^[:alnum:]_])printf([[:space:]]|$)/)) { kw_pos = RSTART + RLENGTH - 1; keyword = "printf" }
    else if (match(body, /(^|[^[:alnum:]_])head[[:space:]]+-c/)) { kw_pos = RSTART + RLENGTH - 1; keyword = "head-c" }
    else if (match(body, /(^|[^[:alnum:]_])cat([[:space:]]|$)/)) { kw_pos = RSTART + RLENGTH - 1; keyword = "cat" }

    if (kw_pos > 0) {
      sp = secret_ref_pos(body)
      if (sp > 0 && sp > kw_pos) {
        print file "|" new_lineno "|" keyword "|" body
        new_lineno++
        next
      }
    }

    new_lineno++
  } else if (ch == " ") {
    new_lineno++
  }
}
')

[ -z "$candidates" ] && exit 0

violations=""
while IFS='|' read -r file lineno reason body; do
  [ -z "$file" ] && continue
  case "$reason" in
    echo|printf|cat)
      msg="$file:$lineno: \`$reason\` referencing a secret-shaped variable — replace with \`\${#VAR}\` length, a comparison, or remove the diagnostic"
      ;;
    head-c)
      msg="$file:$lineno: \`head -c\` near a secret-shaped variable — typically truncate-and-display a secret; remove the call"
      ;;
    substring-expansion)
      msg="$file:$lineno: substring expansion \`\${VAR:N}\` of a secret-shaped variable — exposes a prefix of the secret; use \`\${#VAR}\` length-only or remove"
      ;;
    *)
      msg="$file:$lineno: secret-shaped variable used in an output-producing form"
      ;;
  esac
  violations="${violations}${msg}"$'\n'
done <<<"$candidates"

violations="${violations%$'\n'}"

if [ -n "$violations" ]; then
  mode="${PREPUSH_SECRET_ECHO_BLOCK:-0}"
  if [ "$mode" = "1" ]; then label="FAIL"; rc=1; else label="WARN"; rc=0; fi

  echo "[pre-push-checks] 21-security-secret-echo: $label"
  echo
  echo "  Forbidden forms — \`echo \"\$VAR\"\`, \`printf '%s' \"\$VAR\"\`,"
  echo "  \`head -c N\`, substring \`\${VAR:N:M}\` — write a secret to stdout"
  echo "  where it can leak into logs or a transcript. The following NEW"
  echo "  lines in this diff appear to expose a secret-shaped variable:"
  echo
  printf '    %s\n' "${violations//$'\n'/$'\n    '}"
  echo
  echo "  Fixes:"
  echo "    1. Compare without printing:  [ \"\$A\" = \"\$B\" ]   # safe boolean"
  echo "    2. Need the length:           \${#VAR}"
  echo "    3. Need the value downstream: pass it directly to the command"
  echo "       (e.g. \`gh secret set NAME --body \"\$VAR\"\`), do not echo first."
  echo "    4. PREPUSH_SKIP=21-security git push           # bypass this one rule."
  exit $rc
fi

exit 0
