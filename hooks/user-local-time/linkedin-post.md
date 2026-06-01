# LinkedIn post — `user-local-time` hook

---

If your Claude Code agent runs on a UTC host, it doesn't know what time
it is for you, and will suggest you stop working at the wrong hour.

Fix: a `UserPromptSubmit` hook in `.claude/settings.json` that prepends
one line to every prompt:

`[user-local-time local: 2025-06-15 09:32 (Sunday)]`

Pair it with a memory entry stating your working hours. Set 00:00–24:00
if you don't want shutdown suggestions at all.

14 lines of JSON, install in ~2 minutes:
https://github.com/amurthygithub/Sharevalue_claude_skills/tree/main/hooks/user-local-time

#ClaudeCode #AIAgents
