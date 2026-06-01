---
name: work-on
description: Start work on a <TRACKER> ticket — fetch its details, branch off <STAGING_BRANCH> with a conventional name, acquire a per-branch lock, set status to In Progress, and load context into a file the user's session can read.
argument-hint: <TRACKER_TEAM_KEY>-NNN [--worktree] [--in-place] [--takeover]
allowed-tools: Bash, Read, Write
user-invocable: true
disable-model-invocation: false
---

You are bootstrapping a focused work session on `<TRACKER>` ticket `$1`. The user will continue authoring code in their interactive session; your job is to set the stage so they don't have to context-switch.

## Step 0 — Validate and parse flags

If `$1` is missing or doesn't match `<TRACKER_TEAM_KEY>-\d+`, abort with
`Usage: /work-on <TRACKER_TEAM_KEY>-NNN [--worktree] [--in-place] [--takeover]`.

If `<TRACKER>_API_KEY` is unset, abort with `Error: <TRACKER>_API_KEY not set in environment.`

Flags (all optional):

- `--worktree` → create the branch in a separate `git worktree` so the
  user (or another agent) can keep working in the current checkout in
  parallel.
- `--in-place` → opt out of the auto-promote-to-worktree behavior below.
  Use when you genuinely want to overwrite the existing
  `.claude/active-ticket.md` (e.g., a prior session crashed and left a
  stale pointer).
- `--takeover` → bypass both soft locks (tracker status at Step 1.5 AND
  branch lock at Step 3.5). Use when the previous session is dead/stuck
  and you need to forcibly reclaim. Still subject to the branch-lock
  takeover safeties (refuses live recent locks; refuses when upstream
  has advanced past your HEAD).

If both `--worktree` and `--in-place` are passed, `--worktree` wins (the
safer choice when intent is ambiguous).

**Auto-promote to worktree:** if `.claude/active-ticket.md` already
points at a *different* in-flight ticket, promote this run to `--worktree`
automatically (unless `--in-place`). This protects parallel sessions from
clobbering each other's per-checkout context.

## Step 1 — Fetch the ticket

Use the tracker's API to fetch:
- `id` (UUID), `identifier`, `title`, `description`
- current `state.name`, `parent.identifier` (or null), `labels[].name`

If the ticket doesn't exist, abort with `Error: ticket $1 not found.`

If the ticket is already in `Done` or `Canceled`, warn but continue (the user may be reopening intentionally).

## Step 1.5 — Claim check (soft lock)

Another session may already be mid-flight on `$1`. Refuse to start fresh
work on a ticket whose state is already `In Progress` or `In Review`,
unless either:

- a local branch already exists for this ticket (continuation), or
- the user passed `--takeover` (the prior session is dead and the status
  is stale).

The lock is intentionally *soft*: two agents firing `/work-on` at the exact
same instant can both pass before either claims, and the second will
collide on push. The check exists to catch the far more common case of two
sessions started minutes or hours apart.

```bash
# Continuation: a local branch already exists for this ticket. Any
# Conventional-Commits prefix matches; we only check the ticket slug.
EXISTING_BRANCH=$(git branch --list | sed 's/^[* ]*//' \
  | grep -iE "^[a-z]+/${1,,}-" | head -1)

if [ -z "$EXISTING_BRANCH" ] && [ "$TAKEOVER_FLAG" = "0" ]; then
  case "$STATE_NAME" in
    "In Progress"|"In Review")
      echo "❌ $1 is already claimed (state=$STATE_NAME)."
      echo "   If the previous session is dead, run: /work-on $1 --takeover"
      exit 1
      ;;
  esac
fi
```

## Step 2 — Derive a branch name

Slug the title:
- normalize non-ASCII first via `iconv -c -t ASCII//TRANSLIT` (em-dashes, accented chars, smart quotes — these otherwise survive a `[a-z0-9]+` substitution since the regex matches bytes, not Unicode classes, and produce invalid git ref names)
- lowercase
- replace any non-`[a-z0-9]+` with `-`
- collapse repeated `-`, trim leading/trailing `-`, truncate to 40 chars

```bash
SLUG=$(printf '%s' "$TICKET_TITLE" \
  | iconv -c -t ASCII//TRANSLIT \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
  | cut -c1-40 | sed 's/-$//')
```

Pick a Conventional Commits prefix from labels or title:

- Title starts with `feat`/`add` → `feat`
- Title starts with `fix`/`bug` → `fix`
- Title starts with `refactor` → `refactor`
- Title starts with `docs` → `docs`
- Label includes `Performance` → `perf`
- Label includes `Infrastructure` → `chore`
- Default → `feat`

Final branch name: `<prefix>/<ticket-id-lowercased>-<slug>` (e.g.,
`feat/ticket-123-add-export`). The tracker convention is uppercase
(`TICKET-123`); the branch convention is lowercase.

## Step 3 — Branch off `<STAGING_BRANCH>` (in-place or worktree)

```bash
git fetch origin <STAGING_BRANCH> --quiet
```

### Without `--worktree` (default)

```bash
# Bail on uncommitted changes — don't trash the user's work.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "❌ Uncommitted changes. Stash, commit, or rerun with --worktree to keep this checkout intact."
  exit 1
fi
git checkout -b <branch-name> origin/<STAGING_BRANCH>
```

If the branch already exists locally:
- Same ticket → switch to it (`git checkout <branch-name>`), skip the create.
- Different ticket → abort: `Error: branch <name> already exists. Switch manually or delete it first.`

### With `--worktree`

A `git worktree` is a second checkout of the same repo on disk, on a
different branch, sharing one `.git/` history. The user's current checkout
is left untouched, so multiple sessions/agents can work different tickets
in parallel without trampling each other's working tree.

Path convention: `.claude/worktrees/<ticket-id-lowercased>/` (gitignored).

```bash
WORKTREE_PATH=".claude/worktrees/${1,,}"
if [ -d "$WORKTREE_PATH" ]; then
  echo "❌ $WORKTREE_PATH already exists. Remove it first: git worktree remove $WORKTREE_PATH"
  exit 1
fi
git worktree add -b <branch-name> "$WORKTREE_PATH" origin/<STAGING_BRANCH>
```

All subsequent `git`, `Read`, `Write`, and shell commands in this skill
then operate inside `$WORKTREE_PATH` (`cd` into it). The Step 5 context
file lands in the worktree's `.claude/`, not the original checkout's.

## Step 3.5 — Acquire branch ownership lock

The branch lock is the **push interlock** for `/ship` — if another live
session holds it, `/ship` will hard-refuse the push. `/work-on` halts here
on conflict so the user picks the recovery path *before* coding, not after.

The lock helper records the worktree path, the git user email, the ticket
id, and the HEAD SHA at acquire time. That snapshot is what `--takeover`
later checks against to refuse if origin has advanced.

```bash
# Resolve the lock helper from the MAIN checkout — in a worktree the
# script lives in the main repo's scripts/, not the worktree's.
GIT_COMMON_DIR=$(git rev-parse --git-common-dir)
case "$GIT_COMMON_DIR" in
  /*) ;;
  *)  GIT_COMMON_DIR="$(git rev-parse --show-toplevel)/$GIT_COMMON_DIR" ;;
esac
BRANCH_LOCK="$(dirname "$GIT_COMMON_DIR")/scripts/branch-lock.sh"

BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)
WORKTREE_PATH_ARG="$(pwd)"

if [ ! -x "$BRANCH_LOCK" ]; then
  echo "🛈 branch-lock.sh not found — skipping lock acquire (the lock is push-gating only)."
elif [ "$TAKEOVER_FLAG" = "1" ]; then
  if ! "$BRANCH_LOCK" takeover "$BRANCH_NAME" --reason "takeover for $1"; then
    echo "❌ Takeover refused: the other session is live + recent (<24h) OR has pushed past your HEAD."
    echo "   Open a sibling branch or rebase."
    exit 1
  fi
else
  if ! "$BRANCH_LOCK" acquire "$BRANCH_NAME" "$1" "$WORKTREE_PATH_ARG"; then
    echo "🛑 Branch '$BRANCH_NAME' is locked by another live session. Options:"
    echo "     1. Open a sibling branch for a related ticket."
    echo "     2. Wait for the other session to /ship, then re-run /work-on."
    echo "     3. If it's genuinely stuck/dead: /work-on $1 --takeover"
    exit 1
  fi
fi
```

> Reference helper skeleton: `scripts/branch-lock.sh` should support
> `acquire <branch> <ticket> <worktree-path>`, `takeover <branch> --reason`,
> and `release <branch>`, persist a JSON lock under
> `$GIT_COMMON_DIR/branch-locks/`, auto-expire stale locks (owning worktree
> gone OR age >24h), and emit a runlog shard (Step 8) on every state
> transition: acquire / release / conflict-refused / takeover / cleanup.

## Step 4 — Update the tracker: set status to In Progress

Only if the current state is not already `In Progress` or `In Review`. Use
the tracker's API with state UUID `<TRACKER_STATE_INPROGRESS_UUID>`.

If this fails, log the error but don't abort — the local branch is set up;
the user can update manually.

After the status flips, post an audit-trail comment so future sessions can
see who claimed the ticket and from where — the human-readable counterpart
to the soft lock. Diagnosing a stale claim becomes a one-glance "who has
this and since when":

```
🤖 Claimed by /work-on on branch `<branch-name>` at <ISO UTC> by <git-user-email> (mode: <worktree|in-place>)
```

Failure to post the comment is non-fatal — log and continue.

## Step 5 — Write the ticket context file

Write to `.claude/active-ticket.md` (gitignored — see Step 6) so the user's
interactive session can read it as needed:

```markdown
# Active ticket: <identifier> — <title>

**Status:** <state>  •  **<TRACKER>:** <url>
**Branch:** <branch-name>
**Started:** <ISO UTC>
**Parent:** <parent-identifier-or-none>
**Labels:** <comma-separated-or-none>

## Description

<full description from tracker, untruncated>

---

## Observability checklist (fill before /ship)

<!-- Skip the whole section if no new public endpoint, background job, or
     external integration. See your CLAUDE.md's observability rules. -->
- [ ] New public endpoint, background job, or external integration? If no, skip.
- [ ] SLIs declared: latency p50/p95 = ___, error rate = ___, throughput = ___
- [ ] Latency + result metric on every new external call
- [ ] Schedule + heartbeat monitor registered for any new background job
- [ ] No new f-string log calls in the lazy-formatting zone

---

## Working notes

<empty — user fills as they go>
```

## Step 6 — Ensure `.claude/active-ticket.md` is gitignored

Append `.claude/active-ticket.md` to `.gitignore` if not already present.
Same for `.claude/settings.local.json` and `.claude/worktrees/`. Idempotent.

## Step 7 — Print a tidy summary

Without `--worktree`:

```
✅ Switched to <branch-name> (off origin/<STAGING_BRANCH>)
   Ticket: <identifier> "<title>" — <url>
   Status: <previous-state> → In Progress
   Context written to: .claude/active-ticket.md

You're set. Author your changes, then run /ship when ready.
```

With `--worktree`:

```
✅ Created worktree at <worktree-path>
   Branch:  <branch-name> (off origin/<STAGING_BRANCH>)
   Ticket:  <identifier> "<title>" — <url>
   Status:  <previous-state> → In Progress
   Context: <worktree-path>/.claude/active-ticket.md

Your original checkout is unchanged. Work on this ticket with:
   cd <worktree-path>
/ship from inside the worktree when ready. When done:
   git worktree remove <worktree-path>
```

## Step 8 — Append to the run log (one shard per invocation)

Write a per-invocation shard via a `runlog.sh` helper — **never** `>>` to a
shared log file. Each invocation gets its own uniquely-named file under
`docs/agent-evolution/runs/<UTC-date>/`, so parallel branches never
conflict on the audit trail.

```bash
./scripts/runlog.sh append work-on "$1" \
  "started | branch=<branch-name> | tracker-status=In Progress"
```

> The helper owns the ISO timestamp, filename uniqueness, and directory
> creation. A single shared append-only `RUN_LOG.md` works for a solo
> repo, but breaks down the moment two agents push different branches at
> once — every write collides. Sharded files are the parallel-safe form.

## Notes

- This skill does NOT author code. The user (or a follow-up session) writes the actual changes.
- The `.claude/active-ticket.md` file is the single source of truth for "what am I working on" — `/ship` reads it to derive the commit message and PR title.
