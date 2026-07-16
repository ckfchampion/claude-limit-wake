#!/bin/bash
# claude-notify: banner with the real Claude logo when a VERIFIED icon notifier
# exists; a plain osascript banner (generic icon, always delivers) otherwise.
# Args: $1=title $2=message · or a flag: --test-icon | --trust-icon
#
# Why the gate is a human-verified marker file, not system state: a probe can
# only prove the binary RUNS (-help), not that its banners appear on screen.
# Registration in ncprefs doesn't mean ALLOWED (a denied app is registered
# too), and the allow-state flags bitmask is undocumented and shifts between
# macOS versions. ClaudeNotify (terminal-notifier 2.0, deprecated
# NSUserNotification API) proved the failure mode 2026-07-16 by posting into
# the void while every probe passed. So the icon path activates only after a
# human SAW it work:
#   claude-notify.sh --test-icon    post a test banner through the icon app
#   claude-notify.sh --trust-icon   run this after the Claude-icon banner
#                                   actually appeared on screen
set -u
BIN="$HOME/.claude/helpers/ClaudeNotify.app/Contents/MacOS/terminal-notifier"
MARKER="$HOME/.claude/helpers/.claudenotify-verified"

case "${1:-}" in
  --test-icon)
    [ -x "$BIN" ] || { echo "no icon notifier at $BIN"; exit 1; }
    "$BIN" -title "Claude" -message "Icon test — if you can SEE this banner (Claude icon), run: claude-notify.sh --trust-icon"
    echo "posted. Saw the Claude-icon banner? Then run: $0 --trust-icon"
    exit 0;;
  --trust-icon)
    touch "$MARKER"
    echo "icon path trusted — banners now post via ClaudeNotify.app"
    exit 0;;
esac

TITLE="${1:-Claude}"; MSG="${2:-}"
if [ -f "$MARKER" ] && [ -x "$BIN" ] && "$BIN" -help >/dev/null 2>&1; then
  ( "$BIN" -title "$TITLE" -message "$MSG" >/dev/null 2>&1 & )
else
  # argv-passing form: a payload containing quotes must not become an
  # AppleScript syntax error (the runner's own message quotes "continue").
  ( /usr/bin/osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$TITLE" "$MSG" 2>/dev/null & )
fi
exit 0
