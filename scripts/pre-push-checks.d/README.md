# pre-push rules (`pre-push-checks.d/`)

One file = one rule. The dispatcher (`../pre-push-checks.sh`) enumerates the
executable `*.sh` files here, runs each against the diff you're about to push
(`@{upstream}..HEAD`), and fails the push if any rule blocks. Wire the
dispatcher into your `--quick` lane so it runs from the pre-push hook.

The `.d/` layout exists so a recurring "the agent keeps making this nit"
pattern can graduate from a feedback note to a rule that fires mechanically on
every push — without growing a bespoke hook for each one. A pattern earns a
rule only when it's **mechanical** (a grep / regex / AST walk a ~50-line script
can decide deterministically — if judging it needs an LLM, it belongs at the
`/agentreview` layer) and it catches a **class, not an instance** (seen across
3+ PRs).

## Rule contract

Every rule script:

- Reads only `$PREPUSH_RANGE` from the dispatcher (the diff range, e.g.
  `origin/staging..HEAD`) and greps the diff itself.
- Exits `0` on pass (no finding, or finding suppressed by its env var).
- Exits non-zero only in BLOCK mode with a finding.
- Prints one finding per line as `<path>:<lineno>: <one-sentence message>`,
  followed by a `Fixes:` block that includes the `PREPUSH_SKIP=<prefix>`
  bypass for that rule.
- Starts with `#!/usr/bin/env bash` + `set -uo pipefail` and is `chmod +x`
  (the executable bit is the on/off switch — the dispatcher skips non-exec
  files).

## Numbering + lens prefix

`NN-<lens>-<topic>.sh`. The two-digit prefix sets execution order and groups
the `ls` output by category; the lens segment matches an `/agentreview` lens.

| Range | Category | Lens segment? |
|---|---|---|
| `00-09` | infra / dispatcher self-tests | no |
| `10-19` | `style-` | yes |
| `20-29` | `security-` | yes |
| `30-39` | `correctness-` | yes |
| `90-99` | experimental (allowed to be flaky) | no |

A rule that fits none of style/security/correctness is suspect — usually it's
two rules in a trench coat, or it belongs at a different layer.

## WARN → BLOCK lifecycle (do not skip this)

**Every new rule ships in WARN mode**: it runs and prints findings but exits
`0`, so the push proceeds. A per-rule env var (`PREPUSH_<RULE>_BLOCK=1`) lets a
developer opt into BLOCK mode locally while the rule soaks.

**Backtest before you promote.** Run the candidate against your last ~50
commits on `main`. A false-positive rate under ~10% is the bar for shipping in
WARN; under ~2% is the bar for promoting to BLOCK. Promotion happens in a
separate PR after a soak window with no confirmed false positives (or a
follow-up that tightens the rule), and the decision is recorded in the promote
PR. A rule that BLOCKs on day one with a 30% false-positive rate just trains
everyone to reach for the bypass.

## Two example rules to crib from

This template ships two rules as worked examples — one per common lens. Read
their in-file comments for the WARN/BLOCK env-var switch and the awk/grep
diff-walking shape, then copy the structure for your own rules.

- **`13-style-multiline-comments.sh`** (style) — flags 3+ consecutive
  newly-added single-line comments attached to a non-declaration target.
  Enforces a "default to one short line; multi-line only when the WHY genuinely
  needs it" comment convention. The 3+ threshold and WARN default were both
  chosen *after* backtesting — a 2+ / BLOCK version flagged ~80% of legitimate
  commits. Allows a `// WHY:` / `# WHY:` annotation, or a declaration
  (function / class / decorator / assignment) on the following line. Bypass:
  `PREPUSH_SKIP=13-style git push`.

- **`21-security-secret-echo.sh`** (security) — flags newly-added shell that
  pipes a secret-shaped variable through any stdout-producing form (`echo
  "$VAR"`, `printf '%s' "$VAR"`, `head -c N`, `${VAR:N:M}` slicing). Closes a
  gap a real incident in our own repo named (repeated secret leaks via
  `echo "$VAR"` in a single session). Secret-shaped names are matched on
  generic suffixes (`*_KEY` / `*_TOKEN` / `*_SECRET` / `*_PASSWORD` /
  `*_API_KEY`) anchored at end-of-name, so PATH-suffix variables don't
  false-fire; safe forms (`${#VAR}` length, `[ "$A" = "$B" ]` equality,
  `export VAR=…`) are allowed. Bypass: `PREPUSH_SKIP=21-security git push`.

> The shipped `21-security-secret-echo.sh` here is a SKELETON — it keeps the
> safety logic and the WARN/BLOCK switch but marks the project-specific name
> patterns with `# CUSTOMIZE:`. Adapt the allowlist to the secrets your shell
> actually exports before relying on it.

## Adding a rule

1. Pick the next free `NN-<lens>-<topic>.sh` slot in the right range.
2. Crib from `13-style-multiline-comments.sh`: read `$PREPUSH_RANGE`,
   `git diff --name-only` to enumerate files, awk/grep the unified diff,
   print findings, pick WARN vs BLOCK via env var, exit accordingly.
3. Backtest against your last ~50 commits and record the false-positive rate.
4. `chmod +x` and push. It runs in WARN mode until a later PR promotes it.
