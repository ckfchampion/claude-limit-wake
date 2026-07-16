#!/bin/bash
# claude-notify: banner with the real Claude logo. Args: $1=title $2=message
# Uses the re-iconed ClaudeNotify.app (terminal-notifier's -sender/-appIcon are
# ignored on this macOS; a notification carries the icon of the .app that posts
# it, so we post from a copy whose icon IS Claude's).
# The bundled binary is arch-specific — probe that it actually RUNS on this Mac
# (-help exits 0, costs ~ms) before trusting it: an exec failure inside the
# backgrounded call would eat the banner silently. AND: an app that has never
# registered with Notification Center posts into the void (proven 2026-07-16 —
# no com.champion.claudenotify entry in ncprefs after repeated posts), so the
# Claude-icon path is used only once the bundle id shows up registered there.
# Until then: osascript banner (generic icon, but actually delivered).
set -u
TITLE="${1:-Claude}"; MSG="${2:-}"
BIN="$HOME/.claude/helpers/ClaudeNotify.app/Contents/MacOS/terminal-notifier"
NCPREFS="$HOME/Library/Preferences/com.apple.ncprefs.plist"
if [ -x "$BIN" ] && "$BIN" -help >/dev/null 2>&1 \
   && plutil -p "$NCPREFS" 2>/dev/null | grep -q 'com\.champion\.claudenotify'; then
  ( "$BIN" -title "$TITLE" -message "$MSG" >/dev/null 2>&1 & )
else
  ( /usr/bin/osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$TITLE" "$MSG" 2>/dev/null & )
fi
exit 0
