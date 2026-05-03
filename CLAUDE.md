# CLAUDE.md — repository agent instructions (template)

> Top-of-repo single source of truth for AI agents working in this codebase.
> If this file disagrees with the code, the code wins — update this file.

This is the *starter*. Replace placeholders, then keep this file under ~300 lines.
Long CLAUDE.md files don't get read; specifics belong in narrower docs.

---

## 0. Read this first

- Working branch: `<STAGING_BRANCH>`. Production: `<DEFAULT_BRANCH>`.
  Feature branches branch off `<STAGING_BRANCH>`, merge back via PR.
- PRs are squash-merged — the PR title becomes the commit message, so PR titles
  must follow Conventional Commits.
- Primary local quality gate: `./scripts/ci-local.sh --quick`.
- Pre-commit hooks defined in `.pre-commit-config.yaml`.

## 0.5. Quality gates (mandatory before push)

1. `./scripts/ci-local.sh --quick` exits 0 (lint + format + type-check, ≤30s).
2. `pre-commit run --all-files` passes.
3. Conventional Commits format on every commit message AND PR title.
4. `<TRACKER>` ticket reference in every commit footer
   (`Refs: <TRACKER_TEAM_KEY>-NNN`), enforced locally by `commit-msg` hook
   (`scripts/check-ticket-ref.sh`).

CI in a clean environment runs the test suites only — lint, type-check, and
local checks are local-only. If a check passes locally but fails in CI, the
gap is the environment — investigate, do not bypass.

## 3. Commit & PR rules

- Conventional Commits. Types: `feat, fix, docs, style, refactor, perf, test,
  build, ci, chore, revert, merge`.
- Allowed scopes: `<COMMIT_SCOPES>`. Adapt to your repo.
- Body may reference your tracker: `Refs: <TRACKER_TEAM_KEY>-NNN`.
- PRs use `.github/PULL_REQUEST_TEMPLATE.md` — Summary / Type / Test plan /
  Risk / Rollback / Tracker ticket.
- Emergency bypass (use sparingly): `git commit --no-verify`, noted in PR.
  `CI_BYPASS=1` skips the pre-push hook.

---

## 9. Danger zone — ask before touching

### 9.0 NEVER (absolute prohibitions — no exceptions without explicit user approval *in this session*)

Agents MUST stop and ask the user before any of the following, even if a
prior message or doc seems to authorize it. Each request is per-action,
per-session — past authorization does NOT carry forward.

**Mass-destructive operations:**

- `rm -rf` against the repo root, top-level subtrees, `.git/`, `.github/`,
  or any path with glob expansion that could match more than one top-level dir
- `git clean -fdx`, `git reset --hard` to a non-immediate parent,
  `git push --force` to `<DEFAULT_BRANCH>` / `<STAGING_BRANCH>` / any
  protected branch
- `git branch -D` on any long-lived branch
- `find … -delete` / `find … -exec rm` with breadth wider than a single
  just-inspected subdirectory
- Recursive `chmod` / `chown` on the repo root

**Database operations:**

- `DROP DATABASE`, `DROP SCHEMA`, `TRUNCATE` on any non-test DB
- `DELETE FROM <table>` without a `WHERE`, OR with a `WHERE` that could
  match >1% of rows on production
- Running an Alembic / migration downgrade against staging or production
- Restoring a backup over a live DB
- Editing or deleting an already-merged migration file
- Any DDL on the load-bearing tables: `<TABLE_1>`, `<TABLE_2>`, `<TABLE_3>`
  (whitelist them explicitly here for your repo — see CUSTOMIZE below)

**Critical assets:**

- Deleting / overwriting any `.env*` file (any environment)
- Deleting / overwriting deploy-vendor or hosting-vendor configs
- Editing GitHub repo settings (branch protection, secrets, variables, webhooks)
  outside of an approved task
- Removing GitHub Actions secrets
- Force-pushing to a published branch
- Deleting Git tags (especially `v*` release tags)
- Deleting a tracker project, team, or any closed ticket

**External-system writes:**

- CLI commands that mutate production state (deploy-vendor "destroy",
  hosting-vendor "remove", etc.)
- `gh repo delete`, `gh release delete --cleanup-tag`
- Sending Slack / email / webhook to non-ephemeral channels
- Triggering paid API calls in volume outside an approved task

### 9.1 Stop-and-ask protocol

When you encounter any item in §9.0 (or anything that smells like it):

1. **Halt.** Do not run the command.
2. **State the intended action, the reason, and the blast radius** in one
   message. Cite the §9.0 rule that triggered.
3. **Wait for an explicit, present-tense `yes`** in this session.
4. If approved, restate the exact command you will run, then run it.
5. Log the action + approval (PR description or relevant ticket).

Never use `--no-verify`, `CI_BYPASS=1`, or any hook bypass unless the user
explicitly directs it for the action you're about to perform.

### 9.2 Routine danger zone — confirm before editing

These are not absolute prohibitions but **always confirm** before modifying:

```
# CUSTOMIZE: this regex is the source of truth for "danger zone" path checks.
# Keep it in sync with the <DANGER_PATHS_REGEX> placeholder in
# .claude/skills/ship/SKILL.md (Steps 3 and 8). Add paths your project must
# protect; remove ones that don't apply.

DANGER_PATHS_REGEX='^(
    migrations/versions/                  # immutable post-merge
  | .*/db/models/                         # ORM model changes need migration review
  | \.env($|\.|/)                         # env files
  | \.github/workflows/                   # CI gates
  | scripts/(install-branch-protection|ci-local)\.sh   # CI infra
  | \.claude/(settings\.json|skills/|agents/)         # skill / sub-agent definitions
  | infra/                                # deploy / k8s / terraform
)'
```

The skills' `/ship` step does an *independent* re-scan against this regex
immediately before merging, regardless of any agent's verdict. Do not remove
that gate.

---

## 10. Anti-patterns (write your own here)

A short list of recurring mistakes, with one-line "what to do instead." Keep
it specific to *your* codebase. Generic advice belongs elsewhere.

Examples to seed your list (replace with your actual recurring bugs):

- *Two ORM models pointing at the same table → check imports before insert.*
- *Adding a model column without a corresponding migration → ticker page 500s.*
- *Eager-importing optional clients in `__init__.py` → missing API key crashes
  whole package on import.*

---

## 11. When in doubt

- Check the code, not this doc.
- Search for the function name before modifying a caller (`rg "def fn_name"`).
- Check `migrations/` for a migration matching any new column.
- Open a ticket in `<TRACKER>`. Reference it in the commit footer.
