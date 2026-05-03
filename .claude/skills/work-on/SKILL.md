---
name: work-on
description: Start work on a <TRACKER> ticket — fetch its details, branch off <STAGING_BRANCH> with a conventional name, set status to In Progress, and load context into a file the user's session can read.
argument-hint: <TRACKER_TEAM_KEY>-NNN
allowed-tools: Bash, Read, Write
user-invocable: true
disable-model-invocation: false
---

You are bootstrapping a focused work session on `<TRACKER>` ticket `$1`. The user will continue authoring code in their interactive session; your job is to set the stage so they don't have to context-switch.

## Step 0 — Validate

If `$1` is missing or doesn't match `<TRACKER_TEAM_KEY>-\d+`, abort with `Usage: /work-on <TRACKER_TEAM_KEY>-NNN`.

If `<TRACKER>_API_KEY` is unset, abort with `Error: <TRACKER>_API_KEY not set in environment.`

## Step 1 — Fetch the ticket

Use the tracker's API to fetch:
- `id` (UUID), `identifier`, `title`, `description`
- current `state.name`, `parent.identifier` (or null), `labels[].name`

If the ticket doesn't exist, abort with `Error: ticket $1 not found.`

If the ticket is already in `Done` or `Canceled`, warn but continue (the user may be reopening intentionally).

## Step 2 — Derive a branch name

Slug the title:
- normalize non-ASCII first via `iconv -c -t ASCII//TRANSLIT` (em-dashes, accented chars, smart quotes — these otherwise survive a `[a-z0-9]+` substitution since the regex matches bytes, not Unicode classes, and produce invalid git ref names)
- lowercase
- replace any non-`[a-z0-9]+` with `-`
- collapse repeated `-`
- trim leading/trailing `-`
- truncate to 40 chars

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

Final branch name: `<prefix>/<ticket-id-lowercased>-<slug>` (e.g., `feat/ticket-123-add-screener`).

## Step 3 — Branch off `<STAGING_BRANCH>`

```bash
git fetch origin <STAGING_BRANCH>
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "❌ Uncommitted changes in working tree. Stash or commit before /work-on."
  exit 1
fi
git checkout -b <branch-name> origin/<STAGING_BRANCH>
```

If the branch already exists locally:

- Same ticket → switch to it (`git checkout <branch-name>`).
- Different ticket → abort with `Error: branch <name> already exists. Switch manually or delete it first.`

## Step 4 — Update the tracker: set status to In Progress

Only if current state is not already `In Progress` or `In Review`. Use the tracker's API with state UUID `<TRACKER_STATE_INPROGRESS_UUID>`.

If this fails, log the error but don't abort — the local branch is set up; the user can update manually.

## Step 5 — Write the ticket context file

Write to `.claude/active-ticket.md` (gitignored — see Step 6) so the user's interactive session can read it as needed:

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

## Working notes

<empty — user fills as they go>
```

## Step 6 — Ensure `.claude/active-ticket.md` is gitignored

Append `.claude/active-ticket.md` to `.gitignore` if not already present. Same for `.claude/settings.local.json`. Idempotent.

## Step 7 — Print a tidy summary

```
✅ Switched to <branch-name> (off origin/<STAGING_BRANCH>)
   Ticket: <identifier> "<title>" — <url>
   Status: <previous-state> → In Progress
   Context written to: .claude/active-ticket.md

You're set. Author your changes, then run /ship when ready.
```

## Step 8 — Append to RUN_LOG

Use `>>` to append; **never overwrite the file**.

```bash
echo "<ISO UTC> | /work-on $1 | started | branch=<branch-name> | tracker-status=In Progress" \
  >> docs/agent-evolution/RUN_LOG.md
```

## Notes

- This skill does NOT author code. The user (or a follow-up session) writes the actual changes.
- The `.claude/active-ticket.md` file is the single source of truth for "what am I working on" — `/ship` will read it to derive the commit message and PR title.
