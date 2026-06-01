---
name: linear
description: CLI for <TRACKER> ticket operations (create epic / story / task, update status, show, list) — no committed secrets, reads $<TRACKER>_API_KEY from env. The most-replaceable skill in this template — swap the API layer for any tracker.
argument-hint: <subcommand> <args> — see body
allowed-tools: Bash, Read, Write
user-invocable: true
disable-model-invocation: false
---

You are operating `<TRACKER>` via its API on behalf of the user. Team key: `<TRACKER_TEAM_KEY>`. Team UUID: `<TRACKER_TEAM_UUID>`. Read `$<TRACKER>_API_KEY` from the env (set it in your shell rc, e.g. `~/.zshrc`); NEVER hardcode the token in any file or commit.

This template uses a Linear-style GraphQL API as the worked example. It is the most-replaceable skill here: adapt to Jira, GitHub Issues, Notion, or any tracker by swapping the API-call layer (the `<TRACKER>_gql` helper) and the field names — the subcommand contract stays the same.

## Subcommands

Parse `$ARGUMENTS` as `<subcommand> <rest>`. Supported:

| Subcommand | Args | Effect |
|---|---|---|
| `create-epic` | `<title>` `[--description "..."]` `[--label "..."]` | Create a top-level issue. |
| `create-story` | `<title>` `--epic <TRACKER_TEAM_KEY>-NNN` `[--description "..."]` `[--label "..."]` | Create a child issue under an Epic. |
| `create-task` | `<title>` `--parent <TRACKER_TEAM_KEY>-NNN` `[--description "..."]` `[--label "..."]` | Create a child issue under any parent. |
| `show` | `<TRACKER_TEAM_KEY>-NNN` | Print id, title, state, parent, children, URL. |
| `update` | `<TRACKER_TEAM_KEY>-NNN` `status:<state>` OR `title:"..."` OR `description:"..."` OR `parent:<TRACKER_TEAM_KEY>-NNN` | Update one or more fields. |
| `list` | `[--status <state>]` `[--mine]` `[--limit N]` `[--label "..."]` | List issues from the team. |

Workflow state UUIDs (Linear-style — replace with your tracker's equivalents):

| Name | UUID placeholder |
|---|---|
| Todo | `<TRACKER_STATE_TODO_UUID>` |
| In Progress | `<TRACKER_STATE_INPROGRESS_UUID>` |
| In Review | `<TRACKER_STATE_INREVIEW_UUID>` |
| Done | `<TRACKER_STATE_DONE_UUID>` |

If no `--status` given on create, default to `Todo`.

## Common: send a request

```bash
<TRACKER>_gql() {
  local query="$1"
  curl -sS -X POST <TRACKER_API_BASE> \
    -H "Authorization: $<TRACKER>_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg q "$query" '{query:$q}')"
}
```

Always check the response for `.errors` and abort with the message if present.

## Resolve `<TRACKER_TEAM_KEY>-NNN` → UUID

When a subcommand references a sibling ticket (`--parent`, `--epic`, or `update <id>`), resolve the human identifier to the API UUID first:

```graphql
query { issue(id: "<TRACKER_TEAM_KEY>-NNN") { id identifier title state { name id } } }
```

If the ticket doesn't exist, abort with `Error: ticket not found`.

## create-epic / create-story / create-task

All three use the same `issueCreate` mutation; `parentId` is the only difference.

```graphql
mutation {
  issueCreate(input: {
    teamId: "<TRACKER_TEAM_UUID>"
    title: "<title>"
    description: "<description-or-null>"
    stateId: "<todo-state-uuid>"
    parentId: "<parent-uuid-or-null>"
    labelIds: [<label-uuids-or-empty>]
  }) {
    success
    issue { id identifier title url }
  }
}
```

To resolve a label name → UUID, query the team's labels once per session and cache in memory. After creation, print:

```
✅ Created <identifier> "<title>" — <url>
   Parent: <parent-identifier-or-none>  •  State: <state-name>  •  Labels: <names-or-none>
```

## update

Map `status:<name>` to the workflow state UUID via the table above (case-insensitive match). For `parent:<TRACKER_TEAM_KEY>-NNN`, resolve to UUID first.

```graphql
mutation {
  issueUpdate(id: "<uuid-from-resolve>", input: {
    stateId: "<uuid-or-omit>"
    title: "<value-or-omit>"
    description: "<value-or-omit>"
    parentId: "<uuid-or-omit>"
  }) {
    success
    issue { id identifier title state { name } url }
  }
}
```

Build the `input` dynamically — only include fields the user passed. Print `✅ Updated <identifier>: <changed-fields>`.

## show

```graphql
query {
  issue(id: "<TRACKER_TEAM_KEY>-NNN") {
    id identifier title url
    description
    state { name }
    parent { identifier title }
    children { nodes { identifier title state { name } } }
    labels { nodes { name } }
    assignee { displayName }
    createdAt updatedAt
    comments(first: 5) { nodes { user { displayName } body createdAt } }
  }
}
```

Print as a tidy block. Truncate description to ~500 chars; truncate comment bodies to ~200 chars each.

## list

```graphql
query {
  issues(
    filter: {
      team: { key: { eq: "<TRACKER_TEAM_KEY>" } }
      <optional state filter>
      <optional assignee filter for --mine>
      <optional label filter>
    }
    first: <limit-or-20>
    orderBy: updatedAt
  ) {
    nodes {
      identifier title url
      state { name }
      assignee { displayName }
      updatedAt
    }
  }
}
```

Print as a one-line-per-issue table.

## Logging

After every mutation (create / update only — not show / list), write a
**per-invocation audit shard**, not an append to one shared file. A single
`RUN_LOG.md` serializes parallel sessions and produces merge conflicts the
moment two `/<TRACKER>` invocations run at once; one file per invocation at a
unique path never conflicts.

```bash
# CUSTOMIZE: point this at your own shard helper. It should write a uniquely
# named file under docs/agent-evolution/runs/<UTC-date>/ — one per call.
./scripts/runlog.sh append "<TRACKER> <subcommand>" "<identifier>" \
  "<key=value pairs of what changed>"
```

Keep shard bodies PII-free (repo-relative paths only, no committer email, no
home-dir absolutes) — they are committed to git history.

## Error handling

- Missing `<TRACKER>_API_KEY` → abort with `Error: <TRACKER>_API_KEY not set in environment.`
- Tracker API error → abort with the verbatim error message from the response.
- Unknown subcommand → print the subcommand table above as usage, exit non-zero.
- `create-*` without a title → abort with usage.

## Output style

- One ✅ / ❌ line per top-level result.
- For multi-step operations (resolve → mutate), emit a brief progress line per step.
- Don't print raw API responses unless `--verbose` is in `$ARGUMENTS`.
