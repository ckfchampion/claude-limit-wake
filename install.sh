#!/bin/bash
# install.sh — install the Claude Code limit-wake system on this Mac.
# Idempotent: safe to re-run after a pull to update scripts in place.
#
# What gets installed:
#   ~/.claude/scripts/            limit-wake.sh, limit-wake-runner.sh,
#                                 claude-inject.sh, claude-notify.sh,
#                                 session-tty-hook.sh
#   ~/.claude/helpers/            ClaudeNotify.app (banner with the Claude icon)
#   ~/Library/LaunchAgents/       com.champion.claudelimitwake.plist (60s runner)
#   ~/.claude/settings.json       Stop/SubagentStop/StopFailure -> limit-wake.sh
#                                 SessionStart -> session-tty-hook.sh (hook merge)
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null || { echo "ERROR: jq is required (brew install jq)"; exit 1; }
[ "$(uname)" = "Darwin" ] || { echo "ERROR: macOS only"; exit 1; }

SCRIPTS="$HOME/.claude/scripts"
HELPERS="$HOME/.claude/helpers"
AGENTS="$HOME/Library/LaunchAgents"
SETTINGS="$HOME/.claude/settings.json"
LABEL="com.champion.claudelimitwake"

echo "== scripts -> $SCRIPTS"
mkdir -p "$SCRIPTS" "$HELPERS" "$AGENTS"
install -m 0755 scripts/* "$SCRIPTS/"   # includes the ClaudeLimitWake wrapper (login-item display name)

echo "== ClaudeNotify.app -> $HELPERS"
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
  echo "   *** WARNING: no working notifier binary on this Mac — banners will"
  echo "   *** fall back to osascript (generic icon; grant Notifications"
  echo "   *** permission to Script Editor). For Claude-icon banners:"
  echo "   ***   brew install terminal-notifier && ./install.sh"
fi

echo "== LaunchAgent -> $AGENTS/$LABEL.plist"
sed "s|__HOME__|$HOME|g" "launchagent/$LABEL.plist.template" > "$AGENTS/$LABEL.plist"
plutil -lint "$AGENTS/$LABEL.plist" >/dev/null
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENTS/$LABEL.plist"
launchctl print "gui/$(id -u)/$LABEL" >/dev/null && echo "   runner loaded (fires every 60s)"

echo "== hooks -> $SETTINGS"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
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
  - This watches Claude Code transcripts (~/.claude/projects). Codex sessions
    are NOT covered by this system.
EOF
