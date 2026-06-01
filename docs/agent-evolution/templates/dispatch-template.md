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

- **Pass the ticket ID, not a summary.** Hand the sub-agent the raw
  `<TRACKER_TEAM_KEY>-NNN` and let it fetch the ticket itself. A
  parent-written précis silently drops acceptance criteria and goes stale
  the moment the ticket is edited — the sub-agent then builds the wrong thing
  with confidence. The id is the single source of truth; a summary is a copy
  that rots.
- **Assign explicit, non-overlapping file ownership.** When you fan out more
  than one sub-agent in parallel, give each a disjoint set of paths it owns and
  state it plainly in Constraints (`you own <FRONTEND_DIR>/…; do NOT touch
  <BACKEND_DIR>/…`). Two agents editing the same file race and clobber each
  other; the merge conflict surfaces long after the cheap moment to prevent it.
  No overlap is the contract that makes parallel dispatch safe.
- **Be explicit about scope** — sub-agents over-extend if you don't tell them
  what NOT to touch. The lens definitions in `review-checklist.md` are the
  canonical example.
- **Output format must be parse-stable** — if the orchestrator parses the
  sub-agent's response, define the format with field labels (`VERDICT:`,
  `FINDINGS:`) the orchestrator can grep for.
- **Sub-agents are stateless** — do not assume they can ask questions back.
  Inputs must be complete; there is no second round-trip.
- **Choose the model deliberately:**
  - Larger model (`<MODEL_ORCHESTRATOR>`) for orchestration, multi-step
    planning, ambiguous synthesis.
  - Smaller model (`<MODEL_REVIEWER>`) for focused review, structured output,
    parallel fanout (cheaper, faster).
