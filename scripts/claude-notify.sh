#!/bin/bash
# claude-notify: banner with the real Claude logo. Args: $1=title $2=message
# Uses the re-iconed ClaudeNotify.app (terminal-notifier's -sender/-appIcon are
# ignored on this macOS; a notification carries the icon of the .app that posts
# it, so we post from a copy whose icon IS Claude's).
set -u
TITLE="${1:-Claude}"; MSG="${2:-}"
BIN="$HOME/.claude/helpers/ClaudeNotify.app/Contents/MacOS/terminal-notifier"
if [ -x "$BIN" ]; then
  ( "$BIN" -title "$TITLE" -message "$MSG" >/dev/null 2>&1 & )
else
  ( /usr/bin/osascript -e "display notification \"$MSG\" with title \"$TITLE\"" 2>/dev/null & )
fi
exit 0
