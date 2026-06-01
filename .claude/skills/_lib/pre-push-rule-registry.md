# Playbook: pre-push rule registry

`scripts/pre-push-checks.sh` is a dispatcher that enumerates the rule
scripts in `scripts/pre-push-checks.d/` and runs each against the diff
between `@{upstream}` and `HEAD`. The dispatcher is invoked from
`scripts/ci-local.sh --quick`, which the pre-push git hook runs on every
push.

The registry exists so each "agent keeps making this nit" pattern can
graduate from "rule written down in a feedback memory" to "rule that
fires mechanically on every push" — without growing a bespoke hook for
each one.

## When to add a rule

A pattern earns a rule when **all three** are true:

1. **The rule is mechanical.** A grep, a regex match, an AST walk —
   something a ~50-line bash script can decide deterministically. If
   judging compliance needs a model, it belongs at the `/agentreview`
   layer, not here.
2. **It catches a class, not an instance.** A single bad commit isn't
   enough. The pattern should have shown up across 3+ PRs (or be
   referenced 3+ times across feedback memories).
3. **The backtest is clean enough to ship in WARN mode.** Run the
   candidate against the last ~50 commits on `<DEFAULT_BRANCH>`.
   False-positive rate under ~10% is the bar for WARN; under ~2% is the
   bar for later promoting to BLOCK.

Fails (1) → it stays a memory or an `/agentreview` finding. Fails (2) →
premature. Fails (3) → tighten the rule before it's useful.

## Directory layout

```
scripts/
├── pre-push-checks.sh             ← dispatcher
└── pre-push-checks.d/             ← rules dir
    ├── 0N-<topic>.sh              ← reserved for infra (no lens)
    ├── 13-style-comment-hygiene.sh   ← example shipped rule (the seed)
    ├── 1N-style-<topic>.sh        ← reserved for style
    ├── 2N-security-<topic>.sh     ← reserved for security
    ├── 3N-correctness-<topic>.sh  ← reserved for correctness
    └── 9N-<topic>.sh              ← reserved for experimental (no lens)
```

### Numbering scheme

`NN-<lens>-<topic>.sh` where `NN` is a two-digit prefix that determines
execution order:

| Range | Category | Why this range |
|---|---|---|
| `00-09` | infra / framework | Dispatcher self-tests, env validation. **No `<lens>-` segment.** |
| `10-19` | style | Comment hygiene, naming, layout — fast, deterministic |
| `20-29` | security | Secret echo, auth bypass, injection patterns |
| `30-39` | correctness | Cross-cutting (missing migrations, model drift, etc.) |
| `90-99` | experimental | Rules under evaluation; allowed to be flaky. **No `<lens>-` segment.** |

Only the style/security/correctness ranges carry a `<lens>-` prefix.
Infra (`00-09`) and experimental (`90-99`) use the simpler
`NN-<topic>.sh` form since neither maps to an `/agentreview` lens.

Order within a range doesn't matter; the prefix just makes `ls` produce
a stable, category-grouped listing. Skip numbers (`13-`, then `15-`,
then `17-`) to leave room for future related rules.

### Lens prefixes

`style-` / `security-` / `correctness-` match the three `/agentreview`
lenses. A rule that doesn't fit one of these is suspect — most likely
it's two rules wearing a trench coat, or it belongs at a different
layer.

## Rule contract

Every rule script:

- Reads `$PREPUSH_RANGE` (the diff range string, e.g.
  `origin/<STAGING_BRANCH>..HEAD`) and nothing else from the dispatcher.
- Greps the diff itself (the dispatcher does NOT pre-filter files).
- Exits `0` on pass (no finding, OR finding suppressed by env var).
- Exits non-zero on fail (BLOCK-mode finding).
- Writes one line per finding to stdout as
  `<path>:<lineno>: <one-sentence message>`, followed by a `Fixes:`
  block that lists remediation options — including the `PREPUSH_SKIP`
  bypass for this specific rule.
- Honors `PREPUSH_SKIP=<rule-prefix>` (the dispatcher enforces this, not
  the rule).
- Is `chmod +x` and starts with `#!/usr/bin/env bash` + `set -uo pipefail`.

The dispatcher aggregates exit codes; any non-zero rule fails the push.

## WARN → BLOCK lifecycle

Every new rule ships in **WARN mode**: it runs, prints findings, but
exits `0` so the push proceeds. A per-rule env var
(`PREPUSH_<RULE>_BLOCK=1`) lets a developer opt into BLOCK mode locally
while the rule is still soaking.

Promotion to **BLOCK mode** happens in a *separate* PR, after:

- At least one week of WARN-mode observations.
- Zero confirmed false positives in that window (or a follow-up that
  tightens the rule to eliminate them).
- An explicit decision recorded in the promotion PR description.

> **Backtest before you promote.** Day-1 BLOCK mode turns every false
> positive into a blocking ratchet — exactly the outcome the rule was
> meant to prevent. The soak window exists to catch the false positives
> a backtest missed.

## How to add a rule

1. Pick the next free `NN-<lens>-<topic>.sh` slot in the right range.
2. Write the rule (crib structure from the seed rule):
   `set -uo pipefail`, read `$PREPUSH_RANGE`, `git diff --name-only` to
   enumerate files, grep/awk the unified diff for the pattern, print
   findings, choose WARN vs BLOCK via env var, exit accordingly.
3. Backtest against the last ~50 commits. Keep the backtest snippet
   alongside the rule (or in a CI self-test) so a future reviewer can
   re-run it.
4. Document the bypass env var in the rule's file-header comment AND in
   the dispatcher's failure message.
5. Open a PR. Because `pre-push-checks.d/` lives inside the danger-zone
   path set (see your CLAUDE.md §9.2 / `<DANGER_PATHS_REGEX>`), `/ship`
   will refuse to auto-merge on agent verdict alone — these surfaces
   inherit to every future push for the whole team, so a human must read
   the diff. Merge after consensus + human review.
6. Once landed, **leave the rule in WARN mode** for the soak window.
   Promote to BLOCK in a separate PR.

## How to retire a rule

Three options, increasing in severity:

- **Soft-disable for a single push:** `PREPUSH_SKIP=<rule-prefix> git push`.
  No file change; one-shot.
- **Demote to WARN:** edit the rule to always exit `0` after printing.
  Use when the rule still has signal but produces too many false
  positives to block on.
- **Delete the rule file:** `git rm scripts/pre-push-checks.d/NN-*.sh`.
  Reserved for rules whose underlying antipattern is no longer a concern
  (e.g. the language feature it caught was removed).

Each is a danger-zone edit; merge via the human-gate flow.

## Anti-patterns

- **Shipping a rule in BLOCK mode on day 1.** No soak window → every
  false positive becomes a blocking ratchet.
- **A rule that requires reading semantically.** "Is this docstring
  meaningful?" is not a grep — that's the `/agentreview` style lens.
- **A rule that depends on `git log` or repo history.** The dispatcher
  is per-push, not per-repo. Anything needing aggregate history belongs
  in a CI job, not here.
- **Adding a rule before backtesting.** False-positive rate on real
  commits is the only signal that matters; intuition lies.
- **Re-using a numeric prefix.** `ls` order matters for predictable
  dispatcher failure messages.

## Anti-pattern: skill → rule confusion

The pre-push rule registry is for **mechanical lints**. The layer above
— pattern-shaped checks that need a model to evaluate ("you fixed one
instance; did you sweep for siblings?") — belongs in a review skill, not
here. Don't express a self-review check as a `pre-push-checks.d/` rule,
and don't bury a mechanical lint inside a skill. Each layer has one job.

## Why this lives in `scripts/`, not `.claude/`

`pre-push-checks.{sh,d/}` is plain bash invoked by `ci-local.sh`. It
runs for *every* developer pushing to the repo, not just agent sessions.
Putting it under `.claude/` would imply it's agent-scoped and confuse
anyone reading the directory layout cold. The agent-scoped surface is
`.claude/skills/_lib/` (this playbook) — the docs explaining how to add
rules and what their lifecycle is.
