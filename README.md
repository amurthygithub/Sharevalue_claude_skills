# Public skills template

Sanitized companion to **"Shipping a Production Stack with AI Coding Agents"**
and its follow-up, **"How the Workflow Evolved."** Drop the contents of this
directory into the root of your own repository and adapt the placeholder
values to your stack.

This is the *full* set — the original five skills plus everything the workflow
grew afterward: a fourth review lens, a read-only finding-triage council, a
mid-session handoff, a `_lib/` of shared playbooks, the parallel-agent
coordination primitives (sharded run log, branch lock), and a pre-push rule
engine. Adopt as much or as little as you need; the first two skills
(`/work-on`, `/ship`) still cover ~80% of day-to-day use.

## What's in here

```
.
├─ .claude/
│  ├─ agents/
│  │  ├─ code-reviewer.md                 # Read-only review sub-agent (Read, Glob, Grep only)
│  │  └─ agentreview-orchestrator.md      # Hard-scoped review orchestrator (tool + env scoped)
│  └─ skills/
│     ├─ work-on/SKILL.md                 # /work-on TICKET-NNN   (branch, status, lock, context)
│     ├─ ship/SKILL.md                    # /ship                 (commit, push, review, merge)
│     ├─ agentreview/SKILL.md             # /agentreview <PR>      (4-agent consensus)
│     ├─ triage-review/SKILL.md           # /triage-review         (classify findings, read-only)
│     ├─ promote/SKILL.md                 # /promote               (staging → main, human-gated)
│     ├─ linear/SKILL.md                  # /linear …              (issue-tracker CLI)
│     ├─ handoff/SKILL.md                 # /handoff               (mid-session snapshot)
│     └─ _lib/                            # Shared playbooks (specs, not commands)
│        ├─ README.md
│        ├─ danger-zone-scan.md           # The privileged-path set + why each is on it
│        ├─ agentreview-poll.md           # State machine for polling the review comment
│        ├─ finding-council.md            # The 3-lens finding-triage council
│        └─ pre-push-rule-registry.md     # Numbering, lenses, WARN→BLOCK lifecycle
├─ docs/
│  └─ agent-evolution/
│     ├─ RUN_LOG.md                       # (frozen) legacy single audit log
│     ├─ PARALLEL_WORKFLOW.md             # Sharded logs, worktrees, locks, bg-task discipline
│     ├─ LESSONS_LEARNED.md               # Staging area for repeating lessons
│     ├─ feedback/
│     │  └─ human-corrections.md          # Append-only user-correction log
│     └─ templates/
│        ├─ dispatch-template.md          # Self-contained sub-agent prompt skeleton
│        └─ review-checklist.md           # Four lenses for /agentreview
├─ scripts/
│  ├─ ci-local.sh                         # Quick-gate + pre-push hook installer
│  ├─ check-ticket-ref.sh                 # commit-msg hook for ticket references
│  ├─ danger-zone-scan.sh                 # Shared danger-zone regex + scan helpers
│  ├─ pre-push-checks.sh                  # Rule dispatcher (enumerates pre-push-checks.d/)
│  ├─ pre-push-checks.d/                  # Individual mechanical lint rules
│  │  ├─ README.md
│  │  ├─ 13-style-multiline-comments.sh   # Example STYLE rule (the seed)
│  │  └─ 21-security-secret-echo.sh       # Example SECURITY rule
│  ├─ runlog.sh                           # Sharded audit-trail writer (no shared-file >>)
│  ├─ branch-lock.sh                      # Per-branch ownership lock (push interlock)
│  ├─ agentreview-spawn.sh                # Env-scrub wrapper for the review orchestrator
│  ├─ agentreview-watch.sh                # Heartbeat watcher (emits on every terminal state)
│  ├─ cleanup-agent-reviews.sh            # Orphan-process sweep
│  └─ gh-app-token.sh                     # (optional) Bot identity token for formal approvals
├─ hooks/
│  └─ user-local-time/                    # Example session hook (injects local time)
└─ CLAUDE.md                              # Top-of-repo agent instructions (with §9 NEVER list)
```

## Placeholders you must fill in

These appear throughout the skill files and are intentionally inert until you replace them.

| Placeholder | What it represents | Example |
|---|---|---|
| `<TRACKER>` | Issue tracker name | `Linear`, `Jira`, `GitHub Issues` |
| `<TRACKER_API_BASE>` | Tracker API URL | `https://api.linear.app/graphql` |
| `<TRACKER_TEAM_KEY>` | Short ticket prefix | `TICKET`, `PROJ`, `ENG` |
| `<TRACKER_TEAM_UUID>` | Team UUID for create-mutations | `xxxxxxxx-xxxx-…` |
| `<TRACKER_STATE_*_UUID>` | Workflow-state UUIDs (todo / in-progress / in-review / done) | — |
| `<DEFAULT_BRANCH>` | Production-deployed branch | `main` |
| `<STAGING_BRANCH>` | Pre-production branch | `staging`, `develop` |
| `<BACKEND_DIR>` / `<FRONTEND_DIR>` | Your workspace dirs | `backend`, `web` |
| `<DANGER_PATHS_REGEX>` | Regex of paths that need human approval | see `scripts/danger-zone-scan.sh` |
| `<COMMIT_SCOPES>` | Allowed Conventional Commit scopes | `api,web,db,infra` |
| `<PROD_DOMAIN>` | Production hostname for post-deploy probes | `www.example.com` |
| `<DEPLOY_VENDOR>` / `<HOST_VENDOR>` | Deploy / hosting platforms (in language only) | `Railway`, `Vercel`, etc. |
| `<MODEL_ORCHESTRATOR>` / `<MODEL_REVIEWER>` | Model IDs for /agentreview (larger / smaller) | provider-specific |
| `<BOT_NAME>` + `<BOT_APP_ID>` / `<BOT_INSTALLATION_ID>` / `<BOT_PRIVATE_KEY_PATH>` | (optional) Bot identity for formal PR approvals | — |
| `<agent-cli>` | Your agent runtime CLI | `claude` |

The skills also assume two environment variables on your shell:

- `<TRACKER>_API_KEY` (e.g., `LINEAR_API_KEY`) — for ticket fetches/updates.
- `GH_TOKEN` (or `gh auth login` is sufficient) — for GitHub PR/CLI operations.

The optional bot-approval flow (`scripts/gh-app-token.sh`) additionally reads
`<BOT_APP_ID>` / `<BOT_INSTALLATION_ID>` / `<BOT_PRIVATE_KEY_PATH>`. Leave them
unset and the skills fall back to a normal merge with no loss of safety.

Do **not** commit any of these values. Set them in your shell rc (`~/.zshrc` etc.).

## Quick start

```bash
# 1. Copy the template into a fresh repo
cp -R docs/public-skills-template/. /path/to/your-repo/

# 2. Find every placeholder and fill it in
cd /path/to/your-repo
grep -rl '<TRACKER>\|<DEPLOY_VENDOR>\|<BACKEND_DIR>' .claude/ CLAUDE.md docs/ scripts/

# 3. Install the pre-push hook (quick gate + background review + rule dispatcher)
./scripts/ci-local.sh --install-hook

# 4. Try the cheapest skill first
/work-on TICKET-1
```

## The order to adopt

You do not need all of this on day one. The dependency order that worked for us:

1. **Write your danger zone** (`CLAUDE.md` §9 + `scripts/danger-zone-scan.sh`). Without it, the skills have nothing to refuse.
2. **`/work-on` + `/ship`** — the boilerplate eliminators. Run `/ship` without the merge step until you trust the review.
3. **`/agentreview`** — the four-lens consensus review. Run it manually for a couple of weeks before wiring it to the pre-push hook.
4. **Enable auto-merge in `/ship`** — only after review is reliable. The independent danger-zone re-scan stays a hard gate.
5. **`/promote`** — the production gate, with its two required human confirmations.
6. **The rule engine** (`scripts/pre-push-checks.d/`) — add a rule the third time you correct the same nit. Ship every rule in WARN mode first.
7. **`/triage-review`, `/handoff`, the parallel-agent primitives** — reach for these when the corresponding pain shows up (sorting findings, ending sessions mid-feature, running many agents at once).

## Adapting the danger zone

`CLAUDE.md` ships with a category-organized starter NEVER list. Most categories
apply to everyone (force-push to `main`, dropping production tables, deleting
`.env*`, editing the skill/agent files themselves). The path-specific parts you
must change are tagged `# CUSTOMIZE:`.

The canonical danger-zone regex lives in **one place** —
`scripts/danger-zone-scan.sh` — and every consumer (`/ship` at commit and at
merge, `/promote`, `/agentreview`) sources it. Update the regex there; all
consumers pick up the change. The human-readable rationale for each protected
path lives in `.claude/skills/_lib/danger-zone-scan.md`; keep the two in sync.

The merge gate in `/ship` does an *independent* re-scan against this regex
immediately before merging, regardless of any agent's verdict. **Do not remove
that gate** — it is the defense against a prompt-injected reviewer returning a
fake APPROVE on a privilege-relevant diff.

## What this template is not

- Not a turnkey product. You will edit a few dozen placeholders before anything works.
- Not provider-locked. The skills are Markdown; the agent runtime is yours to choose. The reviewer/orchestrator tool-scoping assumes your runtime supports per-agent tool allowlists — if yours doesn't, run the reviewer as a separate no-shell process.
- Not a substitute for human judgment on irreversible operations. Every skill that *can* halt-and-ask *will* halt-and-ask. Do not edit that out.

## Reference

Full rationale, evolution history, and design principles live in the two
companion papers on the [ShareValue.ai blog](https://www.sharevalue.ai/blog):

- **Shipping a Production Stack with AI Coding Agents** — the original workflow.
- **How the Workflow Evolved** — the fourth review lens, parallel-agent scaling, the rule engine, finding triage, and the hardened orchestrator.

## License

MIT. Adapt freely. Attribution appreciated, not required.
