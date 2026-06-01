# RUN_LOG — Agent skill invocations

Append-only log. One line per invocation. Newest at the bottom.

Format: `<ISO UTC> | /<skill> <args> | <outcome> | <key=value pairs>`

Skills append here automatically (via `scripts/runlog.sh`); do not edit by hand.

> **Single agent vs. many.** This single shared file is fine while one agent
> runs at a time. The moment you run agents in parallel, switch to *sharded*
> per-invocation files under `runs/<UTC-date>/` — a shared append-only file is a
> guaranteed merge conflict across concurrent branches. `runlog.sh` writes
> shards by default; see [`PARALLEL_WORKFLOW.md`](../PARALLEL_WORKFLOW.md).

---
