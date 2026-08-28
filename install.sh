#!/bin/bash
# install.sh — install the Claude Code limit-wake system on this Mac.
# Idempotent: safe to re-run after a pull to update scripts in place.
#
# What gets installed:
#   ~/.claude/scripts/            limit-wake.sh, limit-wake-runner.sh,
#                                 claude-inject.sh, claude-notify.sh,
#                                 session-tty-hook.sh
#   ~/.claude/helpers/            ClaudeNotify.app (banner with the Claude icon)
#   ~/Library/LaunchAgents/       com.claudelimitwake.runner.plist (60s runner)
#   ~/.claude/settings.json       Stop/SubagentStop/StopFailure -> limit-wake.sh
#                                 SessionStart -> session-tty-hook.sh (hook merge;
#                                 a timestamped backup is written first)
# Nothing leaves this machine: no network calls, no telemetry.
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq)"; exit 1; }
[ "$(uname)" = "Darwin" ] || { echo "ERROR: macOS only"; exit 1; }

SCRIPTS="$HOME/.claude/scripts"
HELPERS="$HOME/.claude/helpers"
AGENTS="$HOME/Library/LaunchAgents"
SETTINGS="$HOME/.claude/settings.json"
LABEL="com.claudelimitwake.runner"
LEGACY_LABEL="com.champion.claudelimitwake"   # pre-1.0 installs; unloaded + removed below

echo "== scripts -> $SCRIPTS"
mkdir -p "$SCRIPTS" "$HELPERS" "$AGENTS"
install -m 0755 scripts/* "$SCRIPTS/"   # includes the ClaudeLimitWake wrapper (login-item display name)

echo "== ClaudeNotify.app -> $HELPERS"
# Notification Center permission is keyed on the bundle id. If the installed
# app carries a different id than the one shipping now, the human-verified
# icon trust no longer holds — drop the marker so banners fall back to
# osascript until someone re-verifies by eye (--test-icon / --trust-icon).
# plutil reads the plist file directly; `defaults read` goes through cfprefsd
# and fails (empty) in sandboxed shells, which made this check a silent no-op.
bundle_id() {  # <app bundle> -> CFBundleIdentifier or empty
  /usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}
reset_icon_trust_if_bundle_changed() {  # <installed app> <shipping app> <marker>
  local old new; old="$(bundle_id "$1")"; new="$(bundle_id "$2")"
  [ -f "$3" ] || return 0
  # Fail closed: trust survives only a PROVEN identical id. Unknown/unreadable
  # ids drop the marker too — the cost is one re-verification; the alternative
  # is routing banners through an unverified app that may never show them.
  if [ -z "$new" ] || [ "$old" != "$new" ]; then
    rm -f "$3"
    echo "   notifier bundle id ${new:+changed (${old:-none} -> $new)}${new:-unreadable}: icon trust reset, banners use osascript until re-verified"
  fi
}
reset_icon_trust_if_bundle_changed "$HELPERS/ClaudeNotify.app" "$PWD/helpers/ClaudeNotify.app" "$HELPERS/.claudenotify-verified"
rm -rf "$HELPERS/ClaudeNotify.app"
cp -R helpers/ClaudeNotify.app "$HELPERS/"
xattr -dr com.apple.quarantine "$HELPERS/ClaudeNotify.app" 2>/dev/null || true
codesign --force --deep -s - "$HELPERS/ClaudeNotify.app" 2>/dev/null || true

# The bundled terminal-notifier is arch-specific (built arm64). Probe that it
# actually runs on THIS Mac; if not, swap in the Mach-O from a locally
# installed terminal-notifier (the `terminal-notifier` on PATH is a wrapper
# script — the real binary lives inside its .app bundle; running it from
# inside ClaudeNotify.app keeps the Claude icon). Never leave this silent.
NBIN="$HELPERS/ClaudeNotify.app/Contents/MacOS/terminal-notifier"
if ! "$NBIN" -help >/dev/null 2>&1; then
  echo "   bundled notifier does not run on this Mac ($(uname -m)) — looking for a local one"
  BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  LOCAL_BIN="$(ls "${BREW_PREFIX:-/opt/homebrew}"/Cellar/terminal-notifier/*/terminal-notifier.app/Contents/MacOS/terminal-notifier 2>/dev/null | head -1 || true)"
  [ -n "$LOCAL_BIN" ] || LOCAL_BIN="$(ls /usr/local/Cellar/terminal-notifier/*/terminal-notifier.app/Contents/MacOS/terminal-notifier 2>/dev/null | head -1 || true)"
  if [ -n "$LOCAL_BIN" ] && file -b "$LOCAL_BIN" | grep -q 'Mach-O'; then
    cp "$LOCAL_BIN" "$NBIN"
    codesign --force --deep -s - "$HELPERS/ClaudeNotify.app" 2>/dev/null || true
  fi
fi
if "$NBIN" -help >/dev/null 2>&1; then
  echo "   icon notifier runs. Banners use osascript (generic icon, reliable)"
  echo "   until you verify the icon path by eye:"
  echo "     ~/.claude/scripts/claude-notify.sh --test-icon   (then --trust-icon)"
else
  echo "   *** NOTE: no runnable icon-notifier binary on this Mac — that's fine;"
  echo "   *** banners use osascript regardless until the icon path is verified."
  echo "   *** To make the icon path available: brew install terminal-notifier,"
  echo "   *** re-run ./install.sh, then claude-notify.sh --test-icon / --trust-icon."
fi

echo "== LaunchAgent -> $AGENTS/$LABEL.plist"
sed "s|__HOME__|$HOME|g" "launchagent/$LABEL.plist.template" > "$AGENTS/$LABEL.plist"
plutil -lint "$AGENTS/$LABEL.plist" >/dev/null
launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
rm -f "$AGENTS/$LEGACY_LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENTS/$LABEL.plist"
launchctl print "gui/$(id -u)/$LABEL" >/dev/null && echo "   runner loaded (fires every 60s)"

echo "== hooks -> $SETTINGS"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq empty "$SETTINGS" || { echo "ERROR: $SETTINGS is not valid JSON — fix it before installing hooks"; exit 1; }
BACKUP="$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP" && echo "   backup: $BACKUP"
# ensure_hook <event> <command> <needle> — append the hook to the event unless a
# hook whose command contains <needle> is already registered for it.
ensure_hook() {
  local event="$1" cmd="$2" needle="$3" tmp
  if jq -e --arg e "$event" --arg n "$needle" \
      '.hooks[$e][]?.hooks[]? | select(.command | contains($n))' \
      "$SETTINGS" >/dev/null 2>&1; then
    echo "   $event: already wired"
    return 0
  fi
  tmp="$(mktemp)"
  jq --arg e "$event" --arg c "$cmd" \
     '.hooks[$e] = ((.hooks[$e] // []) + [{matcher:"", hooks:[{type:"command", command:$c, timeout:15}]}])' \
     "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  echo "   $event: hook added"
}
ensure_hook Stop         '~/.claude/scripts/limit-wake.sh'       'limit-wake.sh'
ensure_hook SubagentStop '~/.claude/scripts/limit-wake.sh'       'limit-wake.sh'
ensure_hook StopFailure  '~/.claude/scripts/limit-wake.sh'       'limit-wake.sh'
ensure_hook SessionStart '~/.claude/scripts/session-tty-hook.sh' 'session-tty-hook.sh'
jq empty "$SETTINGS" && echo "   settings.json valid"

echo "== test banner"
"$SCRIPTS/claude-notify.sh" "Claude limit-wake" "Installed on $(hostname -s) — this is the wake-queued banner"

cat <<'EOF'

Done. Two one-time macOS permission grants to check:
  1. NOTIFICATIONS — if no banner just appeared: System Settings > Notifications
     > allow Script Editor (osascript posts as it). For Claude-ICON banners,
     verify by eye: claude-notify.sh --test-icon, then --trust-icon if it showed.
  2. AUTOMATION — the first real wake makes the runner drive Terminal.app; macOS
     will prompt "…wants to control Terminal". Approve it, or the typed
     "continue" falls back to a notification only.

Notes:
  - Injection targets Terminal.app tabs (tty-mapped at SessionStart). Sessions
    in iTerm/VS Code terminals get the fallback notification instead of a typed
    "continue".
  - Claude Code sessions (~/.claude/projects) get the full auto-resume.
    Codex sessions (~/.codex/sessions) get a banner at reset time only.
  - Everything runs locally. Nothing is sent anywhere.
EOF
