# Dispatch template

Used by skills that brief a sub-agent. Concatenate sections in the order shown to produce a self-contained prompt — sub-agents don't see the parent session, so context must be explicit.

---

```markdown
# Task: <one-line description>

## Repo context (always include)

Repo: <PROJECT_NAME> (<STACK_DESCRIPTION>).

Read these in full before starting:
- `CLAUDE.md` (root) — repo guide, conventions, danger zone (§9), anti-patterns (§10)
- (when relevant) `docs/agent-evolution/LESSONS_LEARNED.md` — recent corrections

## Working norms (always include)

- Conventional Commits for any commit you author. PR titles same format.
- Every commit footer: `Refs: <TRACKER_TEAM_KEY>-NNN`.
- Never bypass hooks (`--no-verify`, `CI_BYPASS=1`) unless the user explicitly directed it.
- §9.0 NEVER list: stop and surface to user; do not act.

## Inputs

<task-specific input — file paths, ticket id, diff, etc.>

## Output / deliverable

<what to produce — file edits, JSON verdict, PR comment, etc.>

## Constraints

<task-specific limits — file scope, no-touch list, time/cost ceiling, etc.>
```

---

## Notes for skill authors

- **Be explicit about scope** — sub-agents will over-extend if you don't tell them what NOT to touch. The lens definitions in `review-checklist.md` are the canonical example.
- **Output format must be parse-stable** — if the orchestrator parses the sub-agent's response, define the format with field labels (`VERDICT:`, `FINDINGS:`) the orchestrator can grep for.
- **Sub-agents are stateless** — do not assume they can ask questions back. Inputs must be complete.
- **Choose the model deliberately:**
  - Larger model for orchestration, multi-step planning, ambiguous synthesis
  - Smaller model for focused review, structured output, parallel fanout (cheaper, faster)
