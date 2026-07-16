# claude-limit-wake

Auto-resume Claude Code sessions after a rate limit. When a session dies with
"limit reached · resets 3pm", this system parses the reset time, waits it out
locally (no API needed), then **types `continue` into the exact Terminal tab
the session runs in** — so the session resumes live, on its own.

Built on Charlotte's Mac mini, July 2026. Extracted from `~/.claude/scripts/`
for install on other machines.

## How it works

```
Claude Code session hits a rate limit
        │
        ├─ fast path: Stop/SubagentStop/StopFailure hook → limit-wake.sh
        ├─ reliable path: LaunchAgent runner (every 60s) scans fresh
        │  transcripts for the CLI's own rate_limit error entries
        ▼
limit-wake.sh parses "resets 3pm" → queues a wake file in ~/.claude/limit-wakes/
        + banner: "Limit hit — auto-wake queued for 15:02"
        ▼
limit-wake-runner.sh (LaunchAgent, every 60s) sees a due wake
        ▼
claude-inject.sh types "continue" into the session's Terminal.app tab
(tty recorded per-session by the SessionStart hook). Not a Terminal.app
tab but claude still owns the tty (a Knave-embedded terminal) → the runner
drops a fire-request in ~/.knave/limit-wake-fire/ and the Knave app types
"continue" into its own PTY, deleting the file as the ack. Nothing
consumed it / tab gone → banner telling you to resume by hand. 15-min
cooldown stops re-fire loops.
```

Codex sessions: a second detector (`codex-limit-wake.sh`) reads the
STRUCTURED rate-limit state Codex writes into its rollout logs
(`payload.rate_limits.primary = {used_percent, resets_at}` — no text
parsing) and queues a wake in the same spool. v1 fires a banner at reset
(Codex sessions have no session→tty map yet); weekly-window exhaustion
never arms.

Hard-won details baked in (don't re-learn these):

- **Real 429s only** — it matches the CLI's own `isApiErrorMessage:true` +
  `error:"rate_limit"` transcript entries, never banner text quoted in a
  message (that armed false wakes once).
- **Freshness by entry timestamp**, not file position — the CLI appends
  metadata lines after the 429 entry.
- **Weekly limits (naming a weekday) never arm** — a partial parse must not
  schedule a wake days out.
- **A limit-aborted turn fires NO Stop hook** when the session has no live
  subagents — that's why the 60s transcript scan exists; hooks are only the
  fast path.
- **Injection guard** — `claude-inject.sh` refuses to type into a tty unless a
  `claude` process currently owns it (tabs get recycled).
- **Banners default to osascript** (they post as "Script Editor", generic
  icon) because that path provably delivers. The prettier ClaudeNotify.app
  (re-iconed terminal-notifier — a banner carries the icon of the app that
  posts it; `-sender`/`-appIcon` are silently ignored) uses a deprecated
  API that never registers with Notification Center on macOS 26, so it only
  activates after a human verifies it by eye: `claude-notify.sh --test-icon`,
  then `--trust-icon` if the banner appeared. Never trust a probe that can't
  see the screen.

## Install

```bash
git clone git@github.com:ckfchampion/claude-limit-wake.git
cd claude-limit-wake && ./install.sh
```

Requires: macOS, Claude Code, `jq` (`brew install jq`), sessions running in
**Terminal.app** (iTerm/VS Code sessions still get the "limits reset — resume
manually" banner, just not the typed `continue`).

Two one-time permission grants on a fresh machine (the installer reminds you):

1. **Notifications** — allow **Script Editor** in System Settings >
   Notifications (osascript banners post as it). Style "Alerts" makes them
   stay on screen until dismissed instead of vanishing after a few seconds.
2. **Automation** — approve the "wants to control Terminal" prompt on first fire.

Re-running `install.sh` updates scripts in place; the settings.json hook merge
is idempotent.

## Scope (honest)

- **Claude Code** sessions (scans `~/.claude/projects` transcripts): full
  auto-resume — typed `continue` in Terminal.app tabs and (with the Knave
  desktop app ≥ the limit-wake build) in Knave-embedded terminals.
- **Codex** sessions (scans `~/.codex/sessions` rollout logs): banner at
  reset time only — no typed continue yet (needs a Codex session→tty
  source; phase 2).
- Daily/5h-window limits only; weekly-window limits deliberately never arm
  (a days-out wake is worse than none).

## Files

| File | Role |
|---|---|
| `scripts/limit-wake.sh` | detector: parses the 429 entry, queues the wake, posts the "wake queued" banner |
| `scripts/limit-wake-runner.sh` | LaunchAgent body: 60s heartbeat, transcript + rollout scans, fires due wakes (Terminal.app inject → Knave handoff → manual banner) |
| `scripts/codex-limit-wake.sh` | Codex detector: structured rate_limits from rollout logs → same spool |
| `scripts/claude-inject.sh` | types text into the Terminal tab on a given tty (with claude-owns-tty guard) |
| `scripts/claude-notify.sh` | banner helper — osascript (always delivers) by default; Claude-icon path activates only after human verification (`--test-icon`, then `--trust-icon` once you saw it) |
| `scripts/ClaudeLimitWake` | argv[0] wrapper so the login item shows as "ClaudeLimitWake", not anonymous "bash" |
| `scripts/session-tty-hook.sh` | SessionStart hook: records session-id → tty mapping |
| `helpers/ClaudeNotify.app` | re-iconed terminal-notifier (the icon carrier) |
| `launchagent/…plist.template` | the 60s LaunchAgent, `__HOME__` substituted at install |

## Uninstall

```bash
launchctl bootout "gui/$(id -u)/com.champion.claudelimitwake"
rm ~/Library/LaunchAgents/com.champion.claudelimitwake.plist
# then remove the four hook entries from ~/.claude/settings.json if desired
```
