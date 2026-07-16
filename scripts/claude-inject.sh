#!/bin/bash
# claude-inject: type a line into the Terminal tab living on a given tty.
# Args: $1 = tty (/dev/ttysNNN)   $2 = text (default "continue")
# Exit: 0 injected · 2 bad args · 3 no live claude on that tty · 4 no matching tab
#
# Terminal.app types the text itself (it's the emulator), so this reaches the
# foreground program's stdin — proven against a running `cat` 2026-07-13. This is
# NOT the blocked TIOCSTI keystroke-injection path.
set -u
TTY="${1:-}"; TEXT="${2:-continue}"
case "$TTY" in /dev/ttys*) ;; *) exit 2;; esac
SHORT="${TTY#/dev/}"

# Guard: a claude must currently own this tty — never type into a tab that got
# recycled to some other program. (macOS `pgrep -t` is unreliable for pts, so
# match the ps tty column directly.) INJECT_SKIP_GUARD=1 bypasses (test only).
if [ "${INJECT_SKIP_GUARD:-0}" != "1" ]; then
  # Match a `claude` process on this tty: the EXECUTABLE token ($2, first word
  # of the command column) must be claude — bare or by full path. Checking the
  # whole line let `vim /tmp/claude` / `echo claude` through (Codex review
  # finding, 2026-07-16); the same fix lives in Knave's limitwake guard.
  ps -o tty=,command= 2>/dev/null \
    | awk -v t="$SHORT" '$1==t && $2 ~ /(^|\/)claude$/ {f=1} END{exit !f}' || exit 3
fi

RESULT="$(/usr/bin/osascript - "$TTY" "$TEXT" <<'APPLESCRIPT'
on run argv
  set targetTTY to item 1 of argv
  set theText to item 2 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        try
          if (tty of t) is targetTTY then
            do script theText in t
            return "OK"
          end if
        end try
      end repeat
    end repeat
  end tell
  return "NO-TAB"
end run
APPLESCRIPT
)"
[ "$RESULT" = "OK" ] || exit 4
exit 0
