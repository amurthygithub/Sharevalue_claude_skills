#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ci-local.sh — Local quick-gate + pre-push hook installer (template)
#
# This is a SKELETON. Fill in your project's lint/test/type-check commands
# below. The lanes (backend / frontend / repo-meta) are illustrative — adapt
# to the workspaces your repo actually has.
#
# Split-gates design (the WHY): keep the local lane CHEAP and fast-feedback;
# push the expensive, memory-heavy correctness checks (full test suite) to
# CI in a clean environment. Running the test suite locally AND in CI is
# duplicated work — and locally it can OOM the dev machine when it overlaps
# with the editor + a background agent-review fanout. So: lint + format +
# type-check + repo-meta rules run here; the test suite runs in CI only.
#
# Usage:
#   ./scripts/ci-local.sh              # default: lint + format + type-check
#   ./scripts/ci-local.sh --quick      # ≤30s fast lane (what the hook runs)
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
  --quick         Fast lane only: lint + format + type-check + repo-meta rules (≤30s)
  --install-hook  Install a git pre-push hook (runs --quick + fires /agentreview)

Env (consumed by the installed hook):
  CI_BYPASS=1          Skip ci-local.sh entirely for one push
  SKIP_AGENT_REVIEW=1  Skip only the agent-review fanout for one push
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
# Pre-push hook — split-gates design: the test suite runs in CI, not here.
#
# What this hook does, in order:
#   1. ci-local.sh --quick (lint + format + type-check + repo-meta rules)
#   2. Clean up any orphaned agent-review process trees from prior pushes
#   3. Fire /agentreview in the background for this push's PR (if one exists)
#
# Bypass once: CI_BYPASS=1 git push          (skips ci-local.sh entirely)
# Bypass once: SKIP_AGENT_REVIEW=1 git push  (skips only the review fanout)
# Bypass once: git push --no-verify          (skips all hooks)
#
# Do NOT wire these bypasses into a skill or alias — they exist for genuine
# emergencies and must be a deliberate human choice, noted in the PR.

if [ -n "${CI_BYPASS:-}" ]; then
  echo "[pre-push] CI_BYPASS=1 set — skipping ci-local.sh"
  exit 0
fi

REPO="$(git rev-parse --show-toplevel)"

# Resolve the *common* git dir so background-review state files (PID + log)
# write to the real .git/ even when the hook runs from a `git worktree`
# (where $REPO/.git is a file pointer, not a directory). Normalize to absolute.
GIT_COMMON_DIR="$(git rev-parse --git-common-dir)"
case "$GIT_COMMON_DIR" in
  /*) ;;
  *)  GIT_COMMON_DIR="$REPO/$GIT_COMMON_DIR" ;;
esac

echo "[pre-push] Running local CI (--quick)…"
# Hard gate: any non-zero aborts the push. --quick runs lint + format +
# type-check AND the repo-meta rule dispatcher (scripts/pre-push-checks.sh,
# see the quick lane below). The test suite is intentionally NOT here.
"$REPO/scripts/ci-local.sh" --quick || exit 1

# Sweep up orphaned agent-review process trees from prior pushes BEFORE
# spawning a new one. Cheap, and prevents PID stacking that can hold large
# amounts of virtual memory across many push attempts.
# CUSTOMIZE: provide scripts/cleanup-agent-reviews.sh for your agent runtime,
# or delete this block if you don't run background reviews.
if [ -x "$REPO/scripts/cleanup-agent-reviews.sh" ]; then
  "$REPO/scripts/cleanup-agent-reviews.sh" --quiet || true
fi

# ── Agent review (background, non-blocking) ──────────────────────────────────
# Only fires when:
#   1. Pushing a feature branch (NOT a protected branch)
#   2. A PR already exists for the branch
#   3. SKIP_AGENT_REVIEW is unset
#   4. The agent CLI and gh are on PATH

if [ -n "${SKIP_AGENT_REVIEW:-}" ]; then
  echo "[pre-push] SKIP_AGENT_REVIEW=1 set — skipping agent review"
  exit 0
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
case "$BRANCH" in
  # CUSTOMIZE: protected branches that should never trigger a review
  # (these are merge artifacts of already-reviewed PRs).
  main|staging|production|HEAD)
    exit 0
    ;;
esac

# CUSTOMIZE: replace `claude` with your agent runtime CLI (<agent-cli>).
command -v claude >/dev/null 2>&1 || { echo "[pre-push] agent-cli not found — skipping review"; exit 0; }
command -v gh >/dev/null 2>&1     || { echo "[pre-push] gh CLI not found — skipping review"; exit 0; }

# CUSTOMIZE (optional): a per-branch push interlock for parallel agents.
# If you run many concurrent sessions, a branch-lock helper lets one worktree
# own a branch so another can't race a push. Advisory only — omit if you don't
# run parallel agents.
#   [ -x "$REPO/scripts/branch-lock.sh" ] && "$REPO/scripts/branch-lock.sh" verify "$BRANCH" || true

PR_NUMBER="$(gh pr view --json number -q .number 2>/dev/null || true)"
if [ -z "$PR_NUMBER" ]; then
  echo "[pre-push] No PR found for $BRANCH — skipping review (next push will review)"
  exit 0
fi
case "$PR_NUMBER" in
  ''|*[!0-9]*) echo "[pre-push] PR_NUMBER non-numeric — skipping"; exit 0 ;;
esac

# Per-PR lock/log under the *common* git dir so a worktree push targets the
# parent repo's real .git/ (a push to PR #5 must not kill PR #4's review).
LOCK="$GIT_COMMON_DIR/.agent-review-pr${PR_NUMBER}.pid"
LOG="$GIT_COMMON_DIR/.agent-review-pr${PR_NUMBER}.log"

# Debounce: cancel a previous in-flight review for the SAME PR only.
if [ -f "$LOCK" ]; then
  OLD_PID="$(cat "$LOCK" 2>/dev/null)"
  case "$OLD_PID" in ''|*[!0-9]*) OLD_PID="" ;; esac
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" 2>/dev/null || true
    echo "[pre-push] Canceled in-flight review for PR #$PR_NUMBER (newer push supersedes)"
  fi
fi

# ── Spawn the review fully detached, through a hardened wrapper ───────────────
# SECURITY ENVELOPE (do not weaken):
#   The spawn goes through scripts/agentreview-spawn.sh, a wrapper that
#   hard-scopes the orchestrator's env BEFORE exec-ing the agent: it drops
#   every variable not on a tiny allowlist (keep only the agent's own API
#   key, the tracker key, and gh's token; drop everything else the shell
#   exports — any *_SECRET / *_TOKEN / *_API_KEY / *_PASSWORD). The agent is
#   then launched against a read-only / restricted tool surface so a
#   prompt-injected diff can neither exfiltrate a secret the orchestrator
#   never had nor modify the code under review.
# CUSTOMIZE: implement scripts/agentreview-spawn.sh for your runtime. See
# .claude/skills/agentreview/SKILL.md and .claude/agents/code-reviewer.md
# for the allowed-tools contract.
#
# Detach details: redirect stdin from /dev/null in addition to stdout/stderr
# so git's pre-push doesn't keep the parent shell alive waiting for descendant
# fds to close. A plain `( … ) &` subshell blocks the foreground push for the
# whole review duration because it waits on the inner agent synchronously.
#
# `env -u BASH_ENV -u ENV` closes the BASH_ENV startup-injection window BEFORE
# bash starts the wrapper — the wrapper can't close it from inside (bash
# sources $BASH_ENV before its line 1).
nohup env -u BASH_ENV -u ENV "$REPO/scripts/agentreview-spawn.sh" "$PR_NUMBER" \
  </dev/null >"$LOG" 2>&1 &
REVIEW_PID=$!
echo "$REVIEW_PID" > "$LOCK"
disown 2>/dev/null || true
echo "[pre-push] 🤖 Agent review fired (scoped env + tool surface) in background for PR #$PR_NUMBER (log: $LOG)"
HOOK
  chmod 0755 "$HOOK_FILE"
  echo "Pre-push hook installed at $HOOK_FILE (mode 0755)"
  echo "  Runs: ci-local.sh --quick + background /agentreview (feature branch with an open PR)"
  echo "  Bypass once (skip everything): CI_BYPASS=1 git push"
  echo "  Bypass once (skip only review): SKIP_AGENT_REVIEW=1 git push"
  echo "  Bypass all git hooks:           git push --no-verify"
  echo "  Remove:                         rm $HOOK_FILE"
  exit 0
fi

# ── Quick lane (≤30s) ────────────────────────────────────────────────────────
# CUSTOMIZE: fill in your project's commands here. Keep it under ~30 seconds —
# this runs on every push. Anything slower than that belongs in CI.
echo "Running quick gate…"
FAIL=0

# Example placeholders — replace with your actual tools.
# Backend lane:
# (cd <BACKEND_DIR> && ruff check . && ruff format --check . && mypy app) || FAIL=1

# Frontend lane:
# (cd <FRONTEND_DIR> && npm run lint && npm run type-check) || FAIL=1

# Repo-meta lane:
# pre-commit run --all-files || FAIL=1

# Repo-meta rule dispatcher: walk scripts/pre-push-checks.d/ and run each
# rule against the diff between @{upstream} and HEAD.
#
# WARN→BLOCK ratchet (the WHY): land each new rule in WARN mode first so it
# can't block a push while you measure its false-positive rate against real
# history. Backtest against past commits BEFORE promoting any rule to BLOCK;
# a rule that fires on legitimate diffs trains people to bypass the gate.
# Per-rule env toggles (e.g. PREPUSH_<RULE>_BLOCK=1) promote individual
# rules; PREPUSH_SKIP=<prefix> bypasses one rule for a single push.
# CUSTOMIZE: provide scripts/pre-push-checks.sh + scripts/pre-push-checks.d/.
if [ -x "$REPO_ROOT/scripts/pre-push-checks.sh" ]; then
  "$REPO_ROOT/scripts/pre-push-checks.sh" || FAIL=1
else
  echo "  ▸ Repo: pre-push checks … SKIP (dispatcher missing)"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "❌ quick gate failed"
  exit 1
fi

echo "TODO: replace the commented stubs above with your project's"
echo "      lint / format / type-check commands. Target: <30 seconds total."
exit 0
