# claude-limit-wake

Auto-resume Claude Code sessions after a rate limit. When a session dies with
"limit reached · resets 3pm", this system parses the reset time, waits it out
locally (no API needed), then **types `continue` into the exact Terminal tab
the session runs in** — so the session resumes live, on its own.

macOS only. Everything runs on your machine: no network calls, no telemetry,
no account. It reads your own Claude Code transcripts (`~/.claude/projects`)
to spot the CLI's rate-limit entries, and nothing else.

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
tab but claude still owns the tty (a terminal embedded in another app) → the
runner drops a fire-request in ~/.knave/limit-wake-fire/ and a host app may
type "continue" into its own PTY, deleting the file as the ack. Nothing
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
- **Every call into the notifier binary is bounded.** terminal-notifier 2.0 can
  wait forever on a delivery callback that never fires on macOS 26 — one leaked,
  immortal PPID-1 process per call. On this machine a sibling script accumulated
  ~480 of them, starved `launchservicesd`'s 512-thread pool, and panicked the Mac
  three times (2026-07-16/17/19). The icon path here doesn't use the `-sender`
  flag that provoked it, but it drives the same deprecated binary, so **all three**
  call sites are bounded: the banner and `--test-icon` reap their child after 10s
  (`icon_notify`), and the `-help` liveness probe gives up after 3s and falls back
  to osascript (`bin_healthy`).
  **The reap is verified, not assumed.** `kill(2)` reports that a signal was
  *delivered*, not that the process died, and SIGTERM is catchable — an app
  wedged in its runloop can ignore it. So `reap_child` escalates TERM → KILL,
  polls for the process to actually disappear after each, and `wait`s to collect
  the corpse. It reports success only when the child is provably gone; if one
  ever survives SIGKILL, `--test-icon` says so loudly rather than claiming a
  cleanup that did not happen. Every signal is gated on an exact `(PID, lstart)`
  identity match and fails closed — a recycled PID is never signaled.
  **Liveness and identity are separate questions**, and conflating them is how an
  earlier round of this fix reintroduced the very hang it removes. `kill -0`
  answers "does this PID exist" and cannot fail ambiguously; the `ps` identity
  check answers "may I signal this" and returns *no* on any doubt, including a
  `ps` that simply failed — which is likeliest under exactly the process-table
  pressure being guarded against. Treating that "no" as "the child exited" sent
  the caller into a bare `wait`, which blocks until the child exits: forever, for
  a hung notifier. So `wait` is now reached only once `kill -0` proves the PID is
  gone, and identity doubt resolves by neither signalling nor blocking — the run
  is reported as *unproven*, never as clean. Identity is resolved three ways —
  *ours*, *not ours*, *undetermined* — because only the last is worth retrying;
  both the capture at spawn and every re-check during a reap retry a blind `ps`,
  since the likeliest cause (a `ps` starved by process-table pressure) is
  transient and losing the answer costs the ability to kill that child at all. A
  definite "not ours" short-circuits immediately, and persistent blindness still
  ends fail-closed. If
  `--test-icon` reports that it had to kill the notifier, the delivery callback
  never fired: the banner almost certainly went nowhere, so do **not**
  `--trust-icon` unless you actually saw it.

## Install

```bash
git clone https://github.com/ckfchampion/claude-limit-wake.git
cd claude-limit-wake && ./install.sh
```

Requires: macOS, Claude Code, `jq` (`brew install jq`), sessions running in
**Terminal.app** (iTerm/VS Code sessions still get the "limits reset — resume
manually" banner, just not the typed `continue`).

### What the installer touches

| Path | What |
|---|---|
| `~/.claude/scripts/` | the six scripts below (copied) |
| `~/.claude/helpers/ClaudeNotify.app` | the icon-carrier notifier (copied, ad-hoc signed) |
| `~/Library/LaunchAgents/com.claudelimitwake.runner.plist` | the 60s runner (loaded immediately) |
| `~/.claude/settings.json` | four hooks merged in (`Stop`, `SubagentStop`, `StopFailure`, `SessionStart`); a `settings.json.bak-<timestamp>` copy is written first |

Runtime state lives in `~/.claude/limit-wakes/` (queued wakes, cooldowns),
`~/.claude/session-ttys/` (session → tty map) and
`~/.claude/limit-wake-agent.log`.

Two one-time permission grants on a fresh machine (the installer reminds you):

1. **Notifications** — allow **Script Editor** in System Settings >
   Notifications (osascript banners post as it). Style "Alerts" makes them
   stay on screen until dismissed instead of vanishing after a few seconds.
2. **Automation** — approve the "wants to control Terminal" prompt on first fire.

Re-running `install.sh` updates scripts in place; the settings.json hook merge
is idempotent. Installs from before 1.0 (LaunchAgent label
`com.champion.claudelimitwake`) are unloaded and replaced automatically.

## Scope (honest)

- **Claude Code** sessions (scans `~/.claude/projects` transcripts): full
  auto-resume — typed `continue` in Terminal.app tabs. Sessions in a
  terminal that is not Terminal.app fall back to a banner, unless a host app
  consumes the optional fire-request handoff (see below).
- **Codex** sessions (scans `~/.codex/sessions` rollout logs): banner at
  reset time only — no typed continue yet (needs a Codex session→tty
  source; phase 2).
- Daily/5h-window limits only; weekly-window limits deliberately never arm
  (a days-out wake is worse than none).

### Optional: embedded-terminal handoff

If a `claude` process owns the tty but no Terminal.app tab has it (a terminal
embedded in another app), the runner drops a request file in
`~/.knave/limit-wake-fire/<tty>.json` and waits 6s for a host app to type the
text and delete the file. Nothing consumes it → the request is withdrawn and
you get the "resume manually" banner. If you don't run such a host app this
path is a harmless no-op.

## Files

| File | Role |
|---|---|
| `scripts/limit-wake.sh` | detector: parses the 429 entry, queues the wake, posts the "wake queued" banner |
| `scripts/limit-wake-runner.sh` | LaunchAgent body: 60s heartbeat, transcript + rollout scans, fires due wakes (Terminal.app inject → handoff → manual banner) |
| `scripts/codex-limit-wake.sh` | Codex detector: structured rate_limits from rollout logs → same spool |
| `scripts/claude-inject.sh` | types text into the Terminal tab on a given tty (with claude-owns-tty guard) |
| `scripts/claude-notify.sh` | banner helper — osascript (always delivers) by default; Claude-icon path activates only after human verification (`--test-icon`, then `--trust-icon` once you saw it); every call into the notifier binary is time-bounded (10s banner reap, 3s liveness probe) and the kill is escalated TERM → KILL and verified, so a hang can neither wedge the caller nor leak silently |
| `scripts/ClaudeLimitWake` | argv[0] wrapper so the login item shows as "ClaudeLimitWake", not anonymous "bash" |
| `scripts/session-tty-hook.sh` | SessionStart hook: records session-id → tty mapping |
| `helpers/ClaudeNotify.app` | re-iconed terminal-notifier (the icon carrier) |
| `launchagent/…plist.template` | the 60s LaunchAgent, `__HOME__` substituted at install |
| `tests/run.sh` | offline test suite (detectors, runner fire paths, inject guard) — `./tests/run.sh` |

## Tests

```bash
./tests/run.sh
```

Runs against a throwaway `$HOME` with stubbed notifier/injector, so no
banners are posted and no Terminal is driven. Same suite runs in CI on
macOS (`.github/workflows/test.yml`).

## Uninstall

```bash
launchctl bootout "gui/$(id -u)/com.claudelimitwake.runner"
rm ~/Library/LaunchAgents/com.claudelimitwake.runner.plist
rm -rf ~/.claude/limit-wakes ~/.claude/session-ttys ~/.claude/helpers/ClaudeNotify.app
# then remove the four hook entries from ~/.claude/settings.json (or restore the .bak)
```

## License

MIT — see [LICENSE](LICENSE). Bundled third-party material (terminal-notifier,
the Claude icon) is listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
