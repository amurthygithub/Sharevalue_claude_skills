# LinkedIn post — `user-local-time` hook

> Copy the block below and paste into LinkedIn. ~1,500 chars, sits just
> above the "see more" fold for the hook.

---

Claude Code kept telling me to "wrap for the night" at 3pm.

Because the host machine clock said 22:00 UTC. And the agent had no
idea what timezone I actually live in.

I work an 18-hour day. I was getting four or five false "good night"
suggestions every afternoon.

Fix: one hook, 14 lines of JSON. Every prompt I send now gets a single
line of context prepended on its way to the agent:

`[user-local-time PT: 2026-05-23 21:32 PDT (Saturday)]`

That's it. The agent reads the actual local time and stops inventing
midnight. The "let's pick this up tomorrow" suggestions went away
overnight.

Two ingredients:

1. A `UserPromptSubmit` hook in `.claude/settings.json` that runs
   `TZ=America/Los_Angeles date` and prepends the result. Drop in your
   own IANA timezone.
2. A one-line memory that tells the agent your working hours. Mine:
   06:00 to 24:00 PT. Yours could be 09:00-17:00, or — if you want to
   run 24/7 — just set 00:00-24:00 and the agent will never suggest
   stopping.

That second part is the unlock. The hook gives the agent the *time*.
The memory gives it the *rule*. Together: no more well-meaning
shutdowns at the wrong hour.

Open-sourced the whole thing here, alongside the rest of my agent skill
set (work-on / ship / agentreview / promote / linear):

https://github.com/amurthygithub/Sharevalue_claude_skills/tree/main/hooks/user-local-time

If you've been getting bedtime nudges from your own AI, this is a
five-minute install.

#ClaudeCode #AIAgents #DevTools #DeveloperProductivity
