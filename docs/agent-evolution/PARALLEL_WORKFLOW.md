# Parallel agent workflow

Goal: support **N agents working concurrently** on different tickets in
the same repo without merge conflicts on shared workflow artifacts, and
without going dark on a multi-minute wait.

Four rules keep parallel work conflict-free:

1. Audit-trail writes go through a sharded-log helper, never `>>` to a
   shared file.
2. Each session gets its own `git worktree`.
3. A branch-ownership lock acts as a push interlock.
4. Background-task discipline: pick the right primitive per how many
   notifications you need.

---

## 1. Sharded audit log (no shared write target)

The historical bottleneck: every skill appended one line to the end of a
single tracked file (`docs/agent-evolution/RUN_LOG.md`), so two parallel
branches always conflicted at EOF.

**The fix:** every skill invocation writes its own file with a unique
path, so disjoint adds always auto-merge:

```
docs/agent-evolution/runs/<UTC-date>/<HHMMSSZ>-<skill>-<ticket>-<rand>.log
```

Branch A's PR adds shard files in directories branch B's PR never
touches. Conflicts on the log become structurally impossible.

Use the helper, never raw redirection:

```bash
./scripts/runlog.sh append <skill-name> <ticket-or-dash> "<body-text>"
./scripts/runlog.sh view --skill agentreview --since <YYYY-MM-DD>
```

The legacy flat `RUN_LOG.md` is frozen as a historical archive; a single
writer (e.g. `/promote`) may optionally regenerate it as a flat
human-readable index — one writer at one moment, no concurrency.

**What NOT to do:**

- `echo "…" >> RUN_LOG.md` — bypasses the shard model and reintroduces
  the conflict surface.
- Append to any other repo-wide log file.
- Rewrite the whole shard directory — only ever ADD new files, never
  modify existing ones.

### State-transition logging for coordination primitives

Any coordination primitive (a script other agents/skills gate on —
branch locks, claim files, distributed locks) must emit a shard on
**every state-change transition**: acquire, release, conflict-refused,
takeover, cleanup. Attempted no-ops (e.g. release a lock you don't own)
emit a `*-skipped` variant so the audit trail surfaces misconfigured
callers without pretending the state changed. Shard bodies are committed
to git, so keep them PII-free — repo-relative paths, no developer email,
no home-dir absolutes. Post-incident questions ("why was X locked when I
tried to ship at 2am?") need a timeline, not just a snapshot.

---

## 2. One `git worktree` per session

A `git worktree` is a second checkout of the same repo on disk, on a
different branch, sharing the same `.git/` history. Without worktrees,
two sessions in the same folder fight over the working tree: switching
branches forces stash/restore dances and risks losing work.

Two entry points:

- **Agent-tool isolation** — launch the agent with worktree isolation
  and the harness auto-creates `.claude/worktrees/agent-<random>/`.
- **`/work-on TICKET-NNN --worktree`** — for an interactive session
  where you want your current checkout left intact, the skill creates a
  stable-named worktree at `.claude/worktrees/<ticket-id>/`.

`.claude/worktrees/` is gitignored. Result: as many concurrent sessions
as you want, each with its own working tree, all sharing one `.git/`.

**Discipline that bites in practice:** `cd` into the worktree in EVERY
shell block, not once per session. Tools that bridge state across blocks
only via narrative (cwd, shell vars) drift silently — a verification
scan run from the wrong checkout reports the wrong branch. Print
`pwd && git rev-parse --abbrev-ref HEAD` before any push or scan.

---

## 3. Branch-ownership lock (push interlock)

Worktrees isolate the working tree but do not stop two live sessions
from racing to push the same branch. A per-branch lock closes that gap:

- `/work-on` acquires a lock at
  `$GIT_COMMON_DIR/branch-locks/<branch>.json` recording the owning
  **worktree path** (not PID — the lock must survive the short-lived
  subshells skills spawn).
- `/ship` refuses to push when another live worktree owns the branch.
- The lock **auto-releases** when the owning worktree directory is gone
  OR the lock is older than a staleness threshold (e.g. 24h).
- Manual recovery: `/work-on <TICKET> --takeover`.

The lock is **push-gating only** — it cannot stop another agent from
editing files. For true concurrency on the same surface, coordinate via
tracker status or sibling branches.

Every state-change site emits a runlog shard per §1 (acquire / release /
conflict-refused / takeover / cleanup / release-skipped). Canonicalize
worktree paths against the repo root before logging so no committer
email or home-dir absolute leaks into git history. See
`scripts/branch-lock.sh` for the reference shape — copy the helper and
hook every transition when authoring a new primitive.

---

## 4. Background-task discipline

Pick the primitive by how many notifications you need; never go dark on
a multi-minute wait. Three patterns, no fourth:

| Use case | Primitive | Why |
|---|---|---|
| One-shot completion ("tell me when this finishes") | background process with `until <cond>; do sleep N; done` | Harness tracks the process and notifies on exit. No polling. |
| Periodic visibility + completion (anything 3+ min) | a watcher that emits `[heartbeat]` + terminal-state lines | Each stdout line is a notification — continuous status without the user typing `check`. |
| Parent must exit immediately (e.g. a pre-push git hook) | `nohup … & disown` — the **only** legitimate detached pattern | The hook can't wait; the spawned review must outlive it. Detaching is the design intent. |

The watcher MUST emit on EVERY terminal state (success + stall + failure
+ timeout), not just the happy path — silence is not success. Convention:
heartbeat ≈ 180s for multi-minute waits, stall threshold ≈ 600s. See
`scripts/agentreview-watch.sh` for a reference watcher; the same watcher
retrofits onto detached jobs inherited from a pre-push hook, so there's
no second code path.

---

## 5. When parallel work still genuinely conflicts

The shard pattern eliminates conflicts on the log. It does **not**
eliminate genuine conflicts in shared code. Files that multiple tickets
legitimately edit at once will still conflict:

- **detect-secrets baseline** — updated by any change touching hashed
  strings. Resolution: regenerate after merge (`detect-secrets scan >
  .secrets.baseline`).
- **CI gate script** (`scripts/ci-local.sh`) — only edit when changing
  the gate itself.
- **migration files** — immutable once merged (see CLAUDE.md §9); a
  conflict here indicates a process error, not a merge to resolve.
- **dependency manifests / lockfiles** — multiple tickets adding deps
  conflict on hash regions. Resolution: rebase and re-resolve via your
  package manager.

These are real-code conflicts needing code-level coordination, not a
workflow change.
