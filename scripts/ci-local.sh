#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ci-local.sh — Local quick-gate + pre-push hook installer (template)
#
# This is a SKELETON. Fill in your project's lint/test/type-check commands
# below. Three lanes (API / frontend / repo-meta) are illustrative — adapt
# to the workspaces your repo actually has.
#
# Usage:
#   ./scripts/ci-local.sh              # default: lint + format + type-check
#   ./scripts/ci-local.sh --quick      # ≤30s: same as default, name kept
#                                      # for compatibility with the pre-push
#                                      # hook below
#   ./scripts/ci-local.sh --install-hook # install the git pre-push hook
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INSTALL_HOOK=0
QUICK_MODE=0

for arg in "$@"; do
  case "$arg" in
    --quick) QUICK_MODE=1 ;;
    --install-hook) INSTALL_HOOK=1 ;;
    -h|--help)
      cat <<USAGE
Usage: ci-local.sh [--quick] [--install-hook]
  --quick         Run the fast lane only (lint + format + type-check, ≤30s)
  --install-hook  Install a git pre-push hook (runs --quick + fires /agentreview)
USAGE
      exit 0
      ;;
  esac
done

# ── Install pre-push hook ────────────────────────────────────────────────────
if [ $INSTALL_HOOK -eq 1 ]; then
  HOOK_FILE="$REPO_ROOT/.git/hooks/pre-push"
  if [ -f "$HOOK_FILE" ]; then
    BACKUP="$HOOK_FILE.bak.$(date +%Y%m%d%H%M%S)"
    cp "$HOOK_FILE" "$BACKUP"
    echo "Existing pre-push hook backed up → $BACKUP"
  fi
  cat > "$HOOK_FILE" <<'HOOK'
#!/usr/bin/env bash
# Pre-push hook — runs ci-local.sh --quick + fires /agentreview in background
# Bypass once: CI_BYPASS=1 git push          (skips ci-local.sh entirely)
# Bypass once: SKIP_AGENT_REVIEW=1 git push  (skips only the review fanout)
# Bypass once: git push --no-verify          (skips all hooks)

if [ -n "${CI_BYPASS:-}" ]; then
  echo "[pre-push] CI_BYPASS=1 set — skipping ci-local.sh"
  exit 0
fi

REPO="$(git rev-parse --show-toplevel)"
echo "[pre-push] Running local CI (--quick)…"
"$REPO/scripts/ci-local.sh" --quick || exit 1

# ── Agent review (background, non-blocking) ──────────────────────────────────
# Only fires when:
#   1. Pushing a feature branch (NOT <DEFAULT_BRANCH> / <STAGING_BRANCH>)
#   2. A PR already exists for the branch
#   3. SKIP_AGENT_REVIEW is unset
#   4. <agent-cli> and gh are on PATH

if [ -n "${SKIP_AGENT_REVIEW:-}" ]; then
  echo "[pre-push] SKIP_AGENT_REVIEW=1 set — skipping agent review"
  exit 0
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
case "$BRANCH" in
  # CUSTOMIZE: protected branches that should never trigger a review
  main|staging|production|HEAD)
    exit 0
    ;;
esac

# CUSTOMIZE: replace `claude` with your agent runtime CLI
command -v claude >/dev/null 2>&1 || { echo "[pre-push] agent-cli not found — skipping review"; exit 0; }
command -v gh >/dev/null 2>&1     || { echo "[pre-push] gh CLI not found — skipping review"; exit 0; }

PR_NUMBER="$(gh pr view --json number -q .number 2>/dev/null || true)"
if [ -z "$PR_NUMBER" ]; then
  echo "[pre-push] No PR found for $BRANCH — skipping review (next push will review)"
  exit 0
fi
case "$PR_NUMBER" in
  ''|*[!0-9]*) exit 0 ;;
esac

LOCK="$REPO/.git/.agent-review-pr${PR_NUMBER}.pid"
LOG="$REPO/.git/.agent-review-pr${PR_NUMBER}.log"

if [ -f "$LOCK" ]; then
  OLD_PID="$(cat "$LOCK" 2>/dev/null)"
  case "$OLD_PID" in ''|*[!0-9]*) OLD_PID="" ;; esac
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" 2>/dev/null || true
    echo "[pre-push] Canceled in-flight review for PR #$PR_NUMBER (newer push supersedes)"
  fi
fi

# Spawn detached so `git push` proceeds immediately.
#
# Detach detail: redirect stdin from /dev/null in addition to stdout/stderr so
# git's pre-push doesn't keep the parent shell alive waiting for descendant fds
# to close. The earlier `( ... ) &` subshell pattern blocked the foreground
# push for the full review duration because the subshell waited on the inner
# `nohup claude` synchronously. Lock-file cleanup happens via the `kill -0`
# liveness check above on the next push to the same PR.
nohup claude --print --permission-mode bypassPermissions "/agentreview $PR_NUMBER" \
  </dev/null >"$LOG" 2>&1 &
REVIEW_PID=$!
echo "$REVIEW_PID" > "$LOCK"
disown 2>/dev/null || true
echo "[pre-push] 🤖 Agent review fired in background for PR #$PR_NUMBER (log: $LOG)"
HOOK
  chmod 0755 "$HOOK_FILE"
  echo "Pre-push hook installed at $HOOK_FILE (mode 0755)"
  echo "  Runs: ci-local.sh --quick + background /agentreview"
  echo "  Bypass once (skip everything): CI_BYPASS=1 git push"
  echo "  Bypass once (skip only review): SKIP_AGENT_REVIEW=1 git push"
  echo "  Bypass all git hooks:           git push --no-verify"
  exit 0
fi

# ── Quick lane (≤30s) ────────────────────────────────────────────────────────
# CUSTOMIZE: fill in your project's commands here.
echo "Running quick gate…"

# Example placeholders — replace with your actual tools
# Backend lane:
# (cd apps/api && ruff check . && ruff format --check . && mypy app) || FAIL=1

# Frontend lane:
# (cd web && npm run lint && npm run type-check) || FAIL=1

# Repo-meta lane:
# pre-commit run --all-files || FAIL=1

echo "TODO: replace this stub with your project's lint/format/type-check commands."
echo "      Target: <30 seconds total."
echo ""

exit 0
