# Public skills template

Sanitized companion to **"Shipping a Production Stack with AI Coding Agents."**
Drop the contents of this directory into the root of your own repository and adapt the placeholder values to your stack.

## What's in here

```
.
├─ .claude/
│  ├─ agents/
│  │  └─ code-reviewer.md          # Read-only sub-agent (Read, Glob, Grep only)
│  └─ skills/
│     ├─ work-on/SKILL.md          # /work-on TICKET-NNN
│     ├─ ship/SKILL.md             # /ship  (commit, push, PR, review, merge)
│     ├─ agentreview/SKILL.md      # /agentreview <PR>  (3-agent consensus)
│     ├─ promote/SKILL.md          # /promote  (staging → main, human-gated)
│     └─ linear/SKILL.md           # /linear … (issue-tracker CLI)
├─ docs/
│  └─ agent-evolution/
│     ├─ RUN_LOG.md                # Append-only audit trail
│     ├─ LESSONS_LEARNED.md        # Staging area for repeating lessons
│     ├─ feedback/
│     │  └─ human-corrections.md   # Append-only user-correction log
│     └─ templates/
│        ├─ dispatch-template.md   # Self-contained sub-agent prompt skeleton
│        └─ review-checklist.md    # Three lenses for /agentreview
├─ scripts/
│  ├─ ci-local.sh                  # Local quick-gate + pre-push hook installer
│  └─ check-ticket-ref.sh          # commit-msg hook for ticket references
└─ CLAUDE.md                       # Top-of-repo agent instructions (with §9 NEVER list)
```

## Placeholders you must fill in

These appear throughout the skill files and are intentionally inert until you replace them.

| Placeholder | What it represents | Example |
|---|---|---|
| `<TRACKER>` | Issue tracker name | `Linear`, `Jira`, `GitHub Issues` |
| `<TRACKER_API_BASE>` | Tracker API URL | `https://api.linear.app/graphql` |
| `<TRACKER_TEAM_KEY>` | Short ticket prefix | `TICKET`, `PROJ`, `ENG` |
| `<TRACKER_TEAM_UUID>` | Team UUID for create-mutations | `xxxxxxxx-xxxx-…` |
| `<TRACKER_STATE_TODO_UUID>` | "To do" workflow state UUID | — |
| `<TRACKER_STATE_INPROGRESS_UUID>` | "In progress" workflow state UUID | — |
| `<TRACKER_STATE_INREVIEW_UUID>` | "In review" workflow state UUID | — |
| `<TRACKER_STATE_DONE_UUID>` | "Done" workflow state UUID | — |
| `<DEFAULT_BRANCH>` | Production-deployed branch | `main` |
| `<STAGING_BRANCH>` | Pre-production branch | `staging`, `develop` |
| `<DANGER_PATHS_REGEX>` | Regex of paths that need human approval | see CLAUDE.md §9.2 |
| `<COMMIT_SCOPES>` | Allowed Conventional Commit scopes | `api,web,db,infra` |
| `<PROD_DOMAIN>` | Production hostname for post-deploy curls | `www.example.com` |
| `<DEPLOY_VENDOR>` / `<HOST_VENDOR>` | Deploy / hosting platforms (in language only) | `Railway`, `Vercel`, etc. |
| `<MODEL_ORCHESTRATOR>` / `<MODEL_REVIEWER>` | AI model IDs for /agentreview | provider-specific |

The skills also assume two environment variables on your shell:

- `<TRACKER>_API_KEY` (e.g., `LINEAR_API_KEY`) — for ticket fetches/updates.
- `GH_TOKEN` (or `gh auth login` is sufficient) — for GitHub PR/CLI operations.

Do **not** commit these values. Set them in your shell rc (`~/.zshrc` etc.).

## Quick start

```bash
# 1. Copy the template into a fresh repo
cp -R docs/public-skills-template/. /path/to/your-repo/

# 2. Fill in placeholders (CLAUDE.md and every SKILL.md)
cd /path/to/your-repo
grep -rl '<TRACKER>' .claude/ CLAUDE.md docs/ scripts/

# 3. Install the pre-push hook
./scripts/ci-local.sh --install-hook

# 4. Try the cheapest skill first
/work-on TICKET-1
```

## Adapting the danger zone

`CLAUDE.md` ships with a category-organized starter NEVER list. Most categories apply to everyone (force-push to `main`, dropping production tables, deleting `.env*`). The path-regex parts you'll need to change are tagged `# CUSTOMIZE:`.

The corresponding regex appears in two places — keep them in sync:

- `CLAUDE.md` §9.2 (human-readable list)
- `.claude/skills/ship/SKILL.md` Step 3 + Step 8 (`<DANGER_PATHS_REGEX>` placeholder)

## What this template is not

- Not a turnkey product. You will edit ~30 lines of placeholders before anything works.
- Not provider-locked. The skills are markdown; the underlying agent runtime is yours to choose.
- Not a substitute for human judgment on irreversible operations. Every skill that *can* halt-and-ask *will* halt-and-ask. Do not edit that out.

## Reference

Full rationale, evolution history, and design principles live in the companion whitepaper, published on the [ShareValue.ai blog](https://www.sharevalue.ai/blog) (link will resolve once the post goes live; see the README's commit history if you got here early).

## License

MIT. Adapt freely. Attribution appreciated, not required.
