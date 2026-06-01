#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# pre-push-checks.sh — staged-diff style/correctness rule dispatcher (template)
#
# Enumerates scripts/pre-push-checks.d/*.sh and runs each rule against the diff
# between @{upstream} (what you're about to push) and HEAD. Each rule is a
# self-contained executable that exits non-zero on a blocking finding; this
# dispatcher aggregates exit codes and fails the push if any rule blocked.
#
# The point of the .d/ layout: rules are added one file at a time, each owns a
# numeric prefix and a single lens (style / security / correctness …), and can
# be skipped individually. New rules SHOULD ship in WARN mode (always exit 0,
# just print) and only be promoted to BLOCK after a backtest against recent
# history shows an acceptable false-positive rate. Document that lifecycle for
# your contributors — a rule that BLOCKs on day one with a 30% false-positive
# rate trains everyone to reach for the bypass.
#
# Bypass one rule:  PREPUSH_SKIP=<prefix>,<prefix>… git push
# Bypass the lane:  CI_BYPASS=1 git push   (skips the whole quick gate)
#
# Wire this into ci-local.sh's --quick lane so it runs from the pre-push hook.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_DIR="$SCRIPT_DIR/pre-push-checks.d"

# No rules installed yet → no-op. Lets the template be adopted incrementally.
if [ ! -d "$RULES_DIR" ]; then
  exit 0
fi

# Determine the diff range every rule reads. Prefer @{upstream} (exactly the
# commits about to be pushed); fall back to origin/<STAGING_BRANCH> since most
# feature branches branch off the integration branch.
#
# CUSTOMIZE: replace origin/staging with your integration branch if it differs.
# The final `exit 0` is fail-OPEN by design — a fresh repo or detached HEAD has
# nothing to compare against, so let the push through rather than wedge it.
PREPUSH_RANGE="${PREPUSH_RANGE:-}"
if [ -z "$PREPUSH_RANGE" ]; then
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  if [ -n "$upstream" ] && git rev-parse "$upstream" >/dev/null 2>&1; then
    PREPUSH_RANGE="$upstream..HEAD"
  elif git rev-parse origin/staging >/dev/null 2>&1; then
    PREPUSH_RANGE="origin/staging..HEAD"
  else
    exit 0
  fi
fi
export PREPUSH_RANGE

skip_csv="${PREPUSH_SKIP:-}"
declare -i fail_count=0

# Run each executable rule in lexical (numeric-prefix) order. Honor
# PREPUSH_SKIP=<prefix>,<prefix>… for selective bypass. A non-executable file
# is silently skipped — chmod +x is the on/off switch for a rule.
for rule in "$RULES_DIR"/*.sh; do
  [ -x "$rule" ] || continue
  rule_name="$(basename "$rule" .sh)"

  if [ -n "$skip_csv" ]; then
    IFS=',' read -r -a skipped <<<"$skip_csv"
    skip_this=0
    for s in "${skipped[@]}"; do
      [ -z "$s" ] && continue
      if [[ "$rule_name" == "$s"* ]]; then
        skip_this=1
        echo "[pre-push-checks] SKIP $rule_name (PREPUSH_SKIP)"
        break
      fi
    done
    [ $skip_this -eq 1 ] && continue
  fi

  if ! "$rule"; then
    fail_count=$((fail_count + 1))
  fi
done

if [ $fail_count -gt 0 ]; then
  echo "[pre-push-checks] $fail_count rule(s) failed. See messages above."
  echo "[pre-push-checks] Override one rule: PREPUSH_SKIP=<prefix> git push"
  echo "[pre-push-checks] Override all:     CI_BYPASS=1 git push"
  exit 1
fi

exit 0
