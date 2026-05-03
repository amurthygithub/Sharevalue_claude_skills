---
name: linear
description: CLI for <TRACKER> ticket operations (create epic / story / task, update status, show, list) — no committed secrets, uses $<TRACKER>_API_KEY from env.
argument-hint: <subcommand> <args> — see body
allowed-tools: Bash, Read, Write
user-invocable: true
disable-model-invocation: false
---

You are operating `<TRACKER>` via API on behalf of the user. Team key: `<TRACKER_TEAM_KEY>`. Team UUID: `<TRACKER_TEAM_UUID>`. Use `$<TRACKER>_API_KEY` from the env (already set in `~/.zshrc` or equivalent); NEVER hardcode the token in any file or commit.

This template uses the Linear GraphQL API as the example. Adapt to Jira, GitHub Issues, Notion, or any tracker by replacing the API call layer.

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
| Backlog | `<TRACKER_STATE_BACKLOG_UUID>` |
| Todo | `<TRACKER_STATE_TODO_UUID>` |
| In Progress | `<TRACKER_STATE_INPROGRESS_UUID>` |
| In Review | `<TRACKER_STATE_INREVIEW_UUID>` |
| Done | `<TRACKER_STATE_DONE_UUID>` |
| Canceled | `<TRACKER_STATE_CANCELED_UUID>` |

If no `--status` given on create, default to `Todo`.

## Common: send a request

```bash
linear_gql() {
  local query="$1"
  curl -sS -X POST <TRACKER_API_BASE> \
    -H "Authorization: $<TRACKER>_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg q "$query" '{query:$q}')"
}
```

Always check the response for `.errors` and abort with the message if present.

## Resolve `<TRACKER_TEAM_KEY>-NNN` → UUID

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

Build the `input` dynamically — only include fields the user passed.

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

Print as a tidy block. Truncate description to ~500 chars; truncate comments to ~200 chars each.

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

After every mutation (create / update only — not show / list), append one line to `docs/agent-evolution/RUN_LOG.md`. Use `>>` — **never overwrite the file**.

## Error handling

- Missing `<TRACKER>_API_KEY` → abort with `Error: <TRACKER>_API_KEY not set in environment.`
- Tracker API error → abort with the verbatim error message.
- Unknown subcommand → print usage, exit non-zero.
