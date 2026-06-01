# Playbook: danger-zone path scan

The set of paths whose modification must NOT be auto-merged on an agent
verdict alone, even when the consensus is `✅ APPROVED`. These are the
**privilege-escalation surfaces**: anything that controls how subsequent
agent runs are scoped, what gates fire on push, or what the runtime
trusts at execution time. A poisoned diff that touches one of these
paths must reach a human reviewer before merging.

This file is the **WHY**. The regex itself is the **WHAT** — it lives as
the `<DANGER_PATHS_REGEX>` placeholder in `CLAUDE.md` §9.2 and is mirrored
into `.claude/skills/ship/SKILL.md` (Steps 3 and 8). Keep all three in
sync; if you change the regex, update this table's rationale in the same
commit.

## Canonical regex (mirror)

The load-bearing copy is the `<DANGER_PATHS_REGEX>` in `CLAUDE.md` §9.2.
Mirror, for reference (POSIX extended, anchored at the start of the path):

```regex
^(migrations/versions/|.*/db/models/|\.env($|\.|/)|\.github/workflows/|scripts/(install-branch-protection|ci-local)\.sh|\.claude/(settings\.json|skills/|agents/)|infra/)
```

```
# CUSTOMIZE: this is the starter set. Add the paths YOUR repo must protect
# (your migrations dir, your deploy/IaC dir, your CI-infra scripts, any file
# that re-scopes a future agent run). Remove categories that don't apply.
```

## Why each path is on the list

The categories below are stack-agnostic — every repo has some version of
each. Generalize the concrete path to your layout.

| Category (path) | Why it's privileged |
|---|---|
| Merged migrations (`migrations/versions/`) | Migrations are immutable once merged. A bad migration on `staging` is recoverable; on `main` it touches the production database. |
| ORM models (`.*/db/models/`) | A model change without a matching migration causes 500s on every endpoint that selects the new column. The model and the schema must move together; auto-merging a half of that pair ships a guaranteed outage. |
| `.env` (file, directory, or dotted variant) | Secrets and environment-specific config. A diff here can leak credentials or change runtime behavior the test gate doesn't cover. |
| CI workflows (`.github/workflows/`) | The gates themselves. A workflow change can disable the very check that would have caught a bad PR — auto-merge here is self-undermining. |
| CI-infra scripts (`scripts/install-branch-protection.sh`, `scripts/ci-local.sh`, plus your pre-push hook / review-spawn / branch-lock scripts) | These define what "passes the gate" means for every subsequent push. Branch-protection scripts are irreversible against the live repo. A diff that weakens the pre-push gate, the env-scrub wrapper that hard-scopes a review orchestrator, or the danger-zone scanner itself relaxes the safety envelope for everyone. |
| `.claude/settings.json` | Permission allowlist + MCP/tool wiring. Modifying it changes what the next agent run is allowed to do without prompting. |
| `.claude/skills/` | Slash-command definitions. A diff that edits a `SKILL.md` changes the very skill that's about to run — `/ship` merging the diff that changes `/ship`'s own gates is a self-merging bootstrap. |
| `.claude/agents/` | Sub-agent definitions, including the reviewer's tool allowlist. The read-only reviewer surface is enforced *here*; a diff that adds `Bash` or `Write` to that allowlist breaks defense-in-depth. |
| `CLAUDE.md` (and any nested per-area `CLAUDE.md`) | Top-level agent instructions every session loads — including this skill's own gates. A diff here changes the rules every subsequent agent run operates under. |
| Deploy / IaC (`infra/`) | Terraform / k8s / deploy config. A misconfigured diff can change production topology, expose a service, or relax a network boundary the test gate never exercises. |

Highest leverage of all: the danger-zone scanner script (or regex source)
itself. A diff that drops a path, removes the fail-closed guard, or makes a
helper fail-open silently disables the gate across every consumer at once.
Treat any change to it as the most privileged of the set.

## The 3-dot diff basis (fail-closed)

All git-diff scans use the **3-dot** merge-base form, not tip-vs-tip:

```bash
git diff --name-only "origin/<STAGING_BRANCH>...HEAD"
```

`A...B` returns only the changes B introduces on top of the shared
ancestor — the same shape GitHub's PR review surface and the agent review
diff against. The 2-dot `A..B` tip-vs-tip form false-fires whenever the
branch is behind upstream: it surfaces upstream-only files as if the
branch had touched them, which makes the pre-merge gate refuse clean PRs.

**Fail-closed:** before diffing, confirm the comparison ref is reachable
(`git ls-remote origin <STAGING_BRANCH>`). If it isn't, HALT — do not treat
an unreachable remote as "0 hits." The gate is bypass-resistant by design
and must never run silently.

```bash
# Reference shape. CUSTOMIZE the regex source to your repo.
DANGER_PATHS='<DANGER_PATHS_REGEX>'

git ls-remote --exit-code origin <STAGING_BRANCH> >/dev/null 2>&1 \
  || { echo "🛑 <STAGING_BRANCH> unreachable — cannot run danger-zone scan; halting"; exit 1; }

DANGER_HITS=$(git diff --name-only "origin/<STAGING_BRANCH>...HEAD" | grep -E "$DANGER_PATHS" || true)

if [ -n "$DANGER_HITS" ]; then
  echo "🛑 Danger-zone files in this change set:"
  echo "$DANGER_HITS" | sed 's/^/  - /'
  # surface to the human; do NOT auto-proceed
fi
```

## Two independent gates in `/ship`

The danger-zone check runs in `/ship` at **two** points, by design — do
not collapse them into one:

- **Step 3 — advisory.** Runs at commit time and lets the push + agent
  review proceed so the human reviewer sees the diff with full context.
  Its only job is to print "this PR touches a privileged path" so the
  human can confirm that's expected.
- **Step 8 — hard gate.** Runs immediately before `gh pr merge` and aborts
  regardless of the agent verdict if any path matches. This is the safety
  net for when the Step 3 expectation was wrong.

The Step 8 re-scan is **bash-level and does not trust the agent's text
verdict.** This is the load-bearing defense against a prompt-injected
sub-agent producing a fake `✅ APPROVED` on a privileged diff: even an
`APPROVED` verdict on a diff that touches `.claude/skills/` fails Step 8
and halts the merge. The reviewer sub-agents are also read-only (tool
allowlist `Read, Glob, Grep` — no `Bash`/`Write`), so the worst a poisoned
diff can do is influence verdict text, which this independent gate then
overrides. Two gates, two trust boundaries.

## When to extend the regex

Add a path if **any** of these is true:

- Modifying it could disable a CI gate or relax a permission check.
- Modifying it could leak or change a secret that touches production.
- Modifying it could change what subsequent agent runs are allowed to do.
- It's an immutable-by-policy artifact (release tags, merged migrations).

Update this playbook AND every consumer (`CLAUDE.md` §9.2 and the `/ship`
Steps 3 + 8 regex) in the same PR. Do not silently diverge — drift between
the documented list and the enforced regex is itself a gate failure.
