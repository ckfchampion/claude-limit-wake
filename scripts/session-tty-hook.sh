#!/bin/bash
# session-tty-hook (SessionStart): record this session's controlling tty so the
# limit-wake runner can type "continue" into the exact Terminal tab at reset.
# Keyed on session_id because cwd is NOT unique (worktrees + fleet share dirs).
set -u
PAYLOAD="$(cat)"
SID="$(printf '%s' "$PAYLOAD" | /usr/bin/jq -r '.session_id // empty')"
CWD="$(printf '%s' "$PAYLOAD" | /usr/bin/jq -r '.cwd // empty')"
[ -n "$SID" ] || exit 0

# Walk the parent chain until a real pty appears. The hook's own subprocess is
# detached (tty=??), but the claude TUI upstream owns a ttysNNN (proven 2026-07-13).
pid=$$; depth=0; TTY=""
while [ "${pid:-1}" -gt 1 ] && [ "$depth" -lt 15 ]; do
  t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
  case "$t" in ttys*) TTY="/dev/$t"; break;; esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' '); depth=$((depth+1))
done
[ -n "$TTY" ] || exit 0

MAP="$HOME/.claude/session-ttys"; mkdir -p "$MAP"
/usr/bin/jq -n --arg t "$TTY" --arg c "$CWD" --argjson ts "$(date +%s)" \
  '{tty:$t, cwd:$c, recorded:$ts}' > "$MAP/$SID.json"
exit 0
