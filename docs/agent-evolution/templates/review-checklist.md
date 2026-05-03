# Review checklist (used by `/agentreview`)

Three independent lenses. Each sub-agent reviews its lens only — do not duplicate other lenses.

---

## Correctness lens

- Does the change do what the PR title and body claim?
- Edge cases: empty inputs, `null`/`None`, off-by-one, race conditions, error paths
- Test coverage: are new code paths exercised? Are tests asserting the right thing, not just running?
- Migration safety: backward-compat, downgrade path, locks, dependency discovery (views, FKs)
- Anti-patterns from CLAUDE.md §10 (your project's recurring bugs — fill in with your own)
- Type safety / null handling / async-correctness (no missing `await`, no swallowed exceptions)
- Idempotency: can this run twice safely?

**Out of scope:** style, security (other lenses).

---

## Security / risk lens

- Secrets in code, in env exposure, in commits, in `.env*` files
- AuthN/AuthZ: bypassed middleware on routes that need auth; endpoints missing user-scoping (could leak cross-user data)
- Injection: SQL (raw queries), command injection, XSS, prompt injection in LLM clients
- CDN cache leaks (private response cached publicly): `Cache-Control` overrides should also set `CDN-Cache-Control` and any vendor-specific cache headers
- Blast radius: what breaks if this fails in prod? Rollback path?
- CLAUDE.md §9.0 NEVER list:
  - Mass-destructive ops
  - DDL on load-bearing tables
  - `.env*` edits or removals
  - Branch protection / GH secrets / vendor config edits
  - Force-pushes to long-lived branches
- Rate-limit / DoS exposure on new endpoints (especially LLM-backed)
- Dependency risk: new third-party packages — license, age, maintainer

**Verdict rules for this lens:**

- Any §9.0 hit → blocker
- Any unscoped public endpoint serving user-specific data → blocker
- New committed secret of any kind → blocker

**Out of scope:** style, correctness logic (other lenses).

---

## Style / maintainability lens

- Naming clarity, dead code, premature abstraction (per CLAUDE.md "Doing tasks" rules)
- Comment hygiene:
  - Only WHY when non-obvious
  - No "added for X feature / fix #123" rot
  - No multi-line docstrings on internal helpers
- Inline `style={{ color }}` in React (or your framework's equivalent — breaks theming)
- Semantic tokens over hardcoded `#hex` values
- Test quality: descriptive names, no over-mocking, integration tests not bypassed/`.skip`'d
- File organization, import order, unused imports
- PR title format: Conventional Commits (`feat(scope): …`, `fix(scope): …`, etc.)

**Verdict rules for this lens:**

- Style rarely blocks. Reserve `REQUEST_CHANGES` for things that cause real maintenance pain (dead-code paths, broken theming patterns from §10, deceptively-named functions).
- Otherwise: `COMMENT` for nits, `APPROVE` for clean.

**Out of scope:** correctness logic, security (other lenses).
