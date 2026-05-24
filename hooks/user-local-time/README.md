# `user-local-time` hook

A 14-line Claude Code hook that stops your agent from suggesting "let's call
it a day" at 3pm because the host clock says it's 22:00 UTC.

Every time you send a prompt, the hook prepends one line of context:

```
[user-local-time PT: 2026-05-23 21:32 PDT (Saturday)]
```

The agent sees that on every turn and can stop guessing what timezone you
live in.

## Why this exists

Claude Code runs in whatever timezone the host machine is set to —
frequently UTC. If you live anywhere west of London and work past 5pm
local, the agent will eventually start suggesting you wrap up, get some
sleep, or pick it up tomorrow — based on the wrong clock.

Pair this hook with a one-line **working-hours memory** (see below) and
the agent will respect *your* schedule instead of inventing one. Want a
24/7 window? Set `00:00–24:00`. Want a strict 9-to-5? Set that. The hook
gives the agent the *time*; the memory gives it the *rule*.

## Install

### 1. Drop the hook into your project (or user) settings

Project-level — every teammate working in this repo inherits it:

```bash
# from your repo root
mkdir -p .claude
```

Then edit `.claude/settings.json` and merge this in (create the file if
it doesn't exist):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "printf '[user-local-time PT: %s]\\n' \"$(TZ=America/Los_Angeles date '+%Y-%m-%d %H:%M %Z (%A)' 2>/dev/null || echo unavailable)\""
          }
        ]
      }
    ]
  }
}
```

User-level — applies to every project on your machine, not shared with
teammates: put the same block in `~/.claude/settings.json` instead.

### 2. Change `TZ` and the label to your timezone

Replace `America/Los_Angeles` with your IANA timezone and `PT` with
whatever label reads well in context:

| Where you are | `TZ` value                  | Label  |
| ------------- | --------------------------- | ------ |
| US Pacific    | `America/Los_Angeles`       | `PT`   |
| US Eastern    | `America/New_York`          | `ET`   |
| UK            | `Europe/London`             | `UK`   |
| Central Europe| `Europe/Berlin`             | `CET`  |
| India         | `Asia/Kolkata`              | `IST`  |
| Singapore     | `Asia/Singapore`            | `SGT`  |
| Sydney        | `Australia/Sydney`          | `AEST` |

Find your zone: `ls /usr/share/zoneinfo` (macOS / Linux) or
`timedatectl list-timezones`.

### 3. Tell the agent your working hours

The hook gives the agent the *time*. To stop "go to bed" suggestions,
you also need to tell the agent *when you're awake*. Save this as a
memory in `~/.claude/.../memory/user_working_hours.md` (path varies by
project — `/memory` ask the agent to "save my working hours" and it
will pick the right spot):

```markdown
---
name: user-working-hours
description: User works <START>–<END> <TZ>. Don't suggest stopping before <CUTOFF>.
metadata:
  type: user
---

I work **<START> to <END> <TZ>** every day. <N>-hour window.
Don't suggest stopping until after ~<CUTOFF>, and even then check
with me first.

How to apply:
- Before any "wrap for the night" / "call it a day" / "get some sleep"
  suggestion, look at the `[user-local-time TZ: ...]` line at the top of
  the current prompt.
- If the local time is before <CUTOFF>, do NOT suggest stopping.
```

Fill in your own values. Some examples:

| Schedule              | `<START>` | `<END>` | `<CUTOFF>` |
| --------------------- | --------- | ------- | ---------- |
| Standard 9-to-5       | 09:00     | 17:00   | 17:00      |
| Long maker day        | 06:00     | 24:00   | 23:00      |
| **24/7, no off-hours**| **00:00** | **24:00**| **(none — never suggest stopping)** |
| Nocturnal             | 20:00     | 06:00   | 05:00      |

The 24/7 row is the "I'll stop when I want to" mode. The agent will
treat every hour as a working hour and never volunteer a wind-down.

### 4. Verify

Start a new Claude Code session in the project and send any prompt. The
first line of the agent's view of your message will be the
`[user-local-time ...]` tag. You won't see it in your own UI — it's
prepended on the way to the agent.

You can confirm the hook is firing by running the command directly:

```bash
TZ=America/Los_Angeles date '+%Y-%m-%d %H:%M %Z (%A)'
```

That should print a string like `2026-05-23 21:32 PDT (Saturday)`. If
that works, the hook works.

## How it works (mechanics)

- **Hook type:** `UserPromptSubmit` — fires once per user prompt, before
  the agent's turn starts.
- **What it emits:** standard output from the command is prepended to
  your prompt verbatim (newline-terminated). The agent reads it as plain
  context — nothing magic.
- **Where it runs:** in a subshell on the host machine. `TZ=...` is the
  cleanest cross-platform way to pin the timezone for `date` without
  touching the host's `/etc/localtime`.
- **Failure mode:** if `date` is unavailable (rare — minimal containers,
  busted PATH), the `|| echo unavailable` fallback emits
  `[user-local-time PT: unavailable]` instead of an empty tag. The hook
  never errors the prompt.

## Limits and gotchas

- **The hook runs every prompt.** It's a `date` call, so it's
  microseconds, but be aware that anything you put in a
  `UserPromptSubmit` hook is on the critical path of every turn. Don't
  add network calls.
- **Project-level hooks are inherited by teammates.** If you commit
  this to `.claude/settings.json` in a shared repo, everyone gets it.
  That's usually fine here (it's read-only and trivially cheap), but
  the general principle: review what's in `.claude/settings.json`
  before cloning into a teammate's machine.
- **Sub-agents see it too.** Any agent spawned via the Agent tool also
  receives the line on its prompts. That's a feature for code-review
  and orchestration sub-agents; it's harmless noise for narrow
  one-shot lookups.
- **DST flips happen automatically.** `TZ=America/Los_Angeles` resolves
  PDT in summer and PST in winter; no edit needed.
- **No timeout on the subshell.** `date` is instantaneous in practice,
  so this is fine. If you ever extend the command to do more work, wrap
  it in `timeout 1 ...` to keep the prompt path snappy.

## License

MIT — same as the rest of this repo. Take it, change the timezone, ship
it in your own setup.
