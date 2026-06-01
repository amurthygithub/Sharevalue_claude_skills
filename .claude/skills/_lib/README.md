# `.claude/skills/_lib/` — shared playbooks for skills

Reference material that multiple skills point to instead of duplicating
inline. The agent runtime's skill guidance is that supporting files load
on demand and don't carry per-turn context cost, so reference content
belongs here rather than in `SKILL.md` files.

## What lives here

A **playbook** is a single canonical spec for a primitive shared by
two or more skills. Genericize the table below to your own skills:

| Playbook | Used by | What it specifies |
|---|---|---|
| `danger-zone-scan.md` | `/ship` (Step 3 + pre-merge re-scan), other merge/promote skills | The `<DANGER_PATHS_REGEX>` + matching algorithm + why each path is on the list |
| `agentreview-poll.md` | `/ship` (review-wait step), any skill that consumes a review verdict | The state machine for polling a PR's agent-review comment, anchoring on `HEAD` short-SHA, parsing verdicts and blocker counts |
| `pre-push-rule-registry.md` | Authors of pre-push lint/correctness rules (convention doc, no skill consumers) | Numbering ranges, lens prefixes, WARN→BLOCK lifecycle, exit-code + bypass contracts for the pre-push rule dispatcher |

A playbook with skill consumers is the standard case — "two skills
implement the same logic, a bug fix would need to land in both" is the
cue to extract. A playbook with *no* skill consumers (like a rule
registry) exists when the convention is shared by author-time work that
lives outside `.claude/` (e.g. shell scripts under your pre-push rules
directory). Both are valid; both belong in this index.

## What does NOT live here

- **Slash command files.** Skills live at `.claude/skills/<name>/SKILL.md`.
  `_lib/` is intentionally not a skill (no `SKILL.md` in it) so the
  runtime never tries to invoke it.
- **Executable code.** Shell scripts live in `scripts/`, language-specific
  helpers under their own app dir. Playbooks describe what a skill should
  do; scripts do it.
- **Per-skill prompts.** Lens-specific instructions for a sub-agent (e.g.
  the correctness / security / style checklist used by the reviewer)
  stay with that skill or in a shared templates dir.
- **One-off documentation.** If only one skill ever uses it, keep it
  inline in that skill's `SKILL.md` until a second consumer appears.

## The extract-on-second-consumer rule

Do not extract a playbook on speculation. The moment to extract is when
a **second** skill needs the same primitive — that's when duplicated
logic would force a bug fix to land in two places. Until then, keep the
logic inline in the single skill that uses it.

## How skills reference a playbook

Inside a `SKILL.md` step, link to the playbook with a relative path
from the skill directory, then keep the inline implementation:

```markdown
## Step 3 — Detect danger-zone touches

See `.claude/skills/_lib/danger-zone-scan.md` for the canonical regex
and rationale. The bash below implements the spec.

<bash that does the scan>
```

The skill keeps its inline implementation (so the runtime executes it
without an extra file read); the playbook is the *spec* the bash must
stay true to. If you change one, change the other in the same commit.

## How to add a playbook

1. Confirm two or more skills implement the same primitive.
2. Write the playbook here: state the rule, list every consumer, give
   the canonical algorithm in pseudocode or bash, and explain *why* in
   one paragraph (the reason often outlives the rule).
3. Update each consumer skill's `SKILL.md` to reference the playbook at
   the relevant step.
4. Land all the changes in one PR so the spec and consumers stay in sync.

## Anti-patterns

- Don't add a playbook on speculation. Wait for a second consumer.
- Don't put logic in the playbook that the skills don't have. The
  playbook is a description of *current* behavior, not aspiration.
- **Don't have skills call into each other to reuse logic.** Skill→skill
  composition is not supported by the runtime. If you feel that itch,
  write a shell script in `scripts/` and have both skills call it.
