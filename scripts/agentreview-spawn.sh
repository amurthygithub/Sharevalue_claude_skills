#!/usr/bin/env bash
# Spawn the /agentreview orchestrator with a hard-scoped tool surface and a
# scrubbed environment.
#
# This is the defense-in-depth wrapper that the pre-push hook and /ship use
# to fire an unattended consensus review. It does two security-load-bearing
# things before exec-ing the agent CLI (<agent-cli>):
#
#   1. Scrubs the environment down to an explicit allowlist (default-DROP),
#      so the review session never inherits the secrets your interactive
#      shell exports.
#   2. Spawns the orchestrator as a named, tool-scoped agent with MCP fully
#      disabled, so a prompt-injected diff cannot reach a tool that pushes,
#      merges, or runs arbitrary shell.
#
# Why a wrapper instead of inlining `env -i VAR="$VAR" cmd` in the caller:
#   `env -i VAR=value cmd` passes the value via argv, which appears in
#   /proc/<pid>/cmdline / `ps` output briefly — visible to any local
#   process. This script instead `unset`s the non-allowlisted vars in its
#   OWN shell, then `exec`s the agent CLI — the child inherits the remaining
#   env via execve's envp, which is private to the process. No secret value
#   ever appears in any command line.
#
# Why allowlist-by-name rather than deny-by-regex:
#   The default is DROP. A new secret added to the user's shell later (a
#   future `*_API_KEY`, `*_TOKEN`, etc.) is dropped automatically; only the
#   vars on the explicit allowlist below survive. A regex deny-list would
#   silently forward any newly-added secret that didn't match its patterns —
#   fail-open. This fails closed.
#
# Usage:
#   scripts/agentreview-spawn.sh <PR_NUMBER>
#
# Invoked by:
#   - the pre-push hook (background spawn after a successful push)
#   - .claude/skills/ship/SKILL.md (first-push race spawn, before a PR exists)
#   - manually: scripts/agentreview-spawn.sh 123

set -euo pipefail

# Callers MUST exec this script with BASH_ENV / ENV already stripped
# (e.g. `env -u BASH_ENV -u ENV scripts/agentreview-spawn.sh ...`) — bash
# sources $BASH_ENV at *startup* of a non-interactive shell, BEFORE line 1
# of this script runs. The unset below is belt-and-suspenders for any child
# sub-bash this script spawns; it does NOT close the startup window for THIS
# script. Keep the `env -u` contract in every caller.
unset BASH_ENV ENV

if [ -z "${1:-}" ] || ! [ "$1" -eq "$1" ] 2>/dev/null || [ "$1" -le 0 ]; then
  echo "Usage: scripts/agentreview-spawn.sh <PR_NUMBER>  (positive integer)" >&2
  exit 2
fi
PR_NUMBER="$1"

# Preflight: confirm the agent CLI supports `--agent`. Without this, a future
# CLI that dropped the flag would silently exit non-zero in a nohup background
# spawn — no review fires, no user-visible signal. Cheap, and surfaces the
# problem in the log file. Fail closed; do NOT fall back to an unscoped
# invocation (that defeats the whole point of the wrapper).
#
# CUSTOMIZE: replace `claude` with your agent CLI and adjust the capability
# probe to whatever flag your CLI uses to run a named, tool-scoped agent.
if ! claude --help 2>&1 | grep -qE -- '--agent\b'; then
  echo "ERROR: installed agent CLI does not support the --agent flag." >&2
  echo "  Agent-scoped orchestrator spawn requires it. Refusing to fall back" >&2
  echo "  to an unscoped invocation. Upgrade the CLI and retry." >&2
  exit 3
fi

# Preflight: confirm the CLI can disable MCP servers for this spawn.
#
# WHY disable MCP entirely: depending on the runtime, every MCP server in the
# user-global config can launch at session bootstrap REGARDLESS of an agent's
# tool allowlist. A slow cold-start of any one server (e.g. one that fetches
# and installs its package on first run) can hang the whole spawn before a
# single byte reaches the log. The orchestrator and its sub-agents call zero
# MCP tools here, so dropping every server is lossless. Fail closed if the
# flag is missing rather than silently re-admitting the servers.
#
# CUSTOMIZE: if your CLI has no MCP layer, delete this preflight and the two
# MCP flags on the exec below.
if ! claude --help 2>&1 | grep -qE -- '--strict-mcp-config\b'; then
  echo "ERROR: agent CLI does not support --strict-mcp-config." >&2
  echo "  Spawning with global MCP servers enabled risks a bootstrap hang." >&2
  echo "  Refusing to fall back. Upgrade the CLI and retry." >&2
  exit 4
fi

# ---------------------------------------------------------------------------
# Environment allowlist. Default-DROP everything else.
#
# Update this LIST — never widen it to a regex. Reviewer scrutiny on every
# addition is the point: a new entry here is a new secret you are choosing to
# hand the review session.
#
# Keep ONLY:
#   - Shell + locale basics. PATH especially — the CLI can't find gh/git
#     without it. Locale vars are inert; pass through so downstream tools
#     render dates/numbers correctly.
#   - GitHub CLI auth (gh reads these to authenticate `gh pr view/diff/comment`).
#   - The agent CLI's own auth + optional self-hosted/3P-provider routing
#     (the session won't start without auth; routing flags let users on an
#     alternate provider stay there).
#   - Your issue tracker's API key, IF the orchestrator enriches the comment
#     with ticket data. Drop this line if it doesn't.
#   - Optional bot-identity vars, IF you use a bot account to post a formal
#     PR approval so branch protection is satisfied without admin override.
#     Drop these if you don't.
#
# Do NOT add product secrets here — no payment-provider keys, no auth-provider
# keys, no third-party-data-provider keys, nothing your app needs at runtime.
# The review session reads a diff and posts a comment; it needs none of them.
# As a rule of thumb, anything matching *_SECRET / *_TOKEN / *_API_KEY /
# *_PASSWORD that your shell happens to export should stay DROPPED unless it
# is one of the explicitly-justified entries above.
ALLOWED='HOME PATH USER SHELL TERM LANG
         LC_ALL LC_CTYPE LC_MESSAGES LC_TIME LC_NUMERIC LC_MONETARY LC_COLLATE
         PWD LOGNAME TZ
         XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME
         GH_TOKEN GITHUB_TOKEN
         AGENT_API_KEY AGENT_AUTH_TOKEN AGENT_BASE_URL
         AGENT_USE_PROVIDER_A AGENT_USE_PROVIDER_B
         <TRACKER>_API_KEY
         BOT_APP_ID BOT_APP_INSTALLATION_ID BOT_APP_PRIVATE_KEY_PATH'
# CUSTOMIZE: rename AGENT_* to your CLI's real auth/routing var names; rename
# BOT_* to your bot-identity var names (or delete the line). Keep GH_TOKEN /
# GITHUB_TOKEN and <TRACKER>_API_KEY as-is for the common gh + tracker setup.

# Normalize whitespace for the case-match below.
ALLOWED_NORM=" $(echo "$ALLOWED" | tr -s '[:space:]' ' ') "

# Iterate over every exported env var; unset any not on the allowlist.
# `compgen -e` lists exported var names (bash builtin, no fork). The
# `2>/dev/null || true` matters: bash exports some internals as readonly
# (BASHOPTS, BASH_VERSINFO, ...) in some versions — `unset` returns non-zero
# on those, which under `set -e` would abort the wrapper before exec. We want
# to ignore those refusals, not crash.
for var in $(compgen -e); do
  case "$ALLOWED_NORM" in
    *" $var "*) ;;                          # keep
    *) unset "$var" 2>/dev/null || true ;;  # drop (ignore readonly refusals)
  esac
done

# ---------------------------------------------------------------------------
# exec the agent CLI with the scoped orchestrator agent. The child inherits
# our now-scrubbed env via execve's envp. MCP is fully disabled (see preflight).
#
# Flag ORDER can matter: in some CLIs the MCP-config flags are global session
# flags that MUST precede the agent-selection flag, or the parser rejects them
# once an agent is selected. Verify against your installed CLI version before
# reordering.
#
# CUSTOMIZE:
#   - `--agent agentreview-orchestrator` → your tool-scoped orchestrator agent
#     name (the agent definition is the FIRST line of defense; this script is
#     the second).
#   - `--print` runs non-interactively (one-shot, prints result + exits).
#   - `--permission-mode bypassPermissions` disables per-tool prompts so the
#     review runs unattended. SAFE here ONLY because the orchestrator's tool
#     allowlist and the sub-agents' read-only allowlist are the real gate, and
#     /ship re-scans the danger zone at the bash level before any merge.
#     Do NOT pair bypass-permissions with an un-scoped agent.
exec claude \
  --strict-mcp-config \
  --mcp-config '{"mcpServers":{}}' \
  --agent agentreview-orchestrator \
  --print \
  --permission-mode bypassPermissions \
  "/agentreview $PR_NUMBER"
