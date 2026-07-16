#!/bin/bash
# limit-wake (scheduler half): run every 60s by the com.champion.claudelimitwake
# LaunchAgent (a GUI-session agent — cron can't control Terminal via AppleScript).
#   1. heartbeat — stamps $SPOOL/.last-run so "is the agent running?" is answerable.
#   2. scan — feeds freshly-written main transcripts through limit-wake.sh.
#      A limit-aborted turn fires NO Stop/SubagentStop hook (proven 2026-07-11),
#      so this scan is the reliable catch; the hooks are the fast path.
#   3. fire — for each due wake, TYPE "continue" into the exact Terminal tab the
#      session runs in (session->tty map from the SessionStart hook), so Charlotte
#      watches it resume live. Falls back to a notification if the tab is gone.
#      A per-session cooldown stops a self-triggered re-limit from re-firing.

set -u
# GUI-agent PATH is bare — resumed sessions need node/homebrew for their hooks.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
SPOOL="$HOME/.claude/limit-wakes"
MAP="$HOME/.claude/session-ttys"
DETECTOR="$HOME/.claude/scripts/limit-wake.sh"
INJECT="$HOME/.claude/scripts/claude-inject.sh"
NOTIFY="$HOME/.claude/scripts/claude-notify.sh"
COOLDOWN_SECS=900   # 15 min: after an auto-continue, don't re-arm this session
mkdir -p "$SPOOL" "$MAP"
date +%s > "$SPOOL/.last-run"
NOW=$(date +%s)

notify() {  # title, message
  [ -x "$NOTIFY" ] && "$NOTIFY" "$1" "$2" 2>/dev/null &
}

# -- scan: transcripts written in the last 3 min (subagent files excluded) --
/usr/bin/find "$HOME/.claude/projects" -name '*.jsonl' -mmin -3 \
    -not -path '*/subagents/*' 2>/dev/null |
while IFS= read -r T; do
  META="$(tail -n 200 "$T" | /usr/bin/jq -rs \
    '[.[] | select(.isApiErrorMessage == true and .error == "rate_limit")]
     | last | if . == null then empty
       else ((.sessionId // .session_id // "") + "\t" + (.cwd // "")) end' 2>/dev/null)"
  [ -n "$META" ] || continue
  SID="$(printf '%s' "$META" | cut -f1)"
  SCWD="$(printf '%s' "$META" | cut -f2-)"
  [ -n "$SID" ] || continue
  /usr/bin/jq -n --arg s "$SID" --arg t "$T" --arg c "$SCWD" \
    '{session_id:$s, transcript_path:$t, cwd:$c}' | "$DETECTOR" >/dev/null 2>&1
done

# -- fire due wakes --
for FILE in "$SPOOL"/*.json; do
  [ -f "$FILE" ] || continue
  TARGET="$(/usr/bin/jq -r '.target // 0' "$FILE")"
  case "$TARGET" in (""|*[!0-9]*) rm -f "$FILE"; continue;; esac
  [ "$NOW" -ge "$TARGET" ] || continue

  SESSION="$(/usr/bin/jq -r '.session // empty' "$FILE")"
  rm -f "$FILE"   # consume first — a crashing fire must not loop
  [ -n "$SESSION" ] || continue

  # loop-guard: skip if this session was auto-continued within the cooldown
  CD="$SPOOL/.cooldown-$SESSION"
  if [ -f "$CD" ] && [ "$NOW" -lt "$(cat "$CD" 2>/dev/null || echo 0)" ]; then
    continue
  fi

  MAPF="$MAP/$SESSION.json"
  TTY="$(/usr/bin/jq -r '.tty // empty' "$MAPF" 2>/dev/null)"
  SHORT8="${SESSION:0:8}"

  if [ -n "$TTY" ] && "$INJECT" "$TTY" "continue"; then
    echo "$((NOW + COOLDOWN_SECS))" > "$CD"
    notify "Claude limit-wake" "Typed \"continue\" into session $SHORT8 ($TTY)"
  else
    RC=$?
    # exit 4 = a claude owns the tty but no Terminal.app tab has it — likely a
    # Knave-embedded terminal. Hand off: drop a fire-request file; Knave's
    # watcher types the text and DELETES the file as its ack (2s poll → 6s wait).
    FIRED=""
    if [ "$RC" = "4" ]; then
      FIREDIR="$HOME/.knave/limit-wake-fire"
      REQ="$FIREDIR/${TTY#/dev/}.json"
      # file-gone is the ack, so it only counts if creation provably succeeded —
      # a failed write here must fall through to the manual banner, never read
      # as "Knave consumed it".
      if mkdir -p "$FIREDIR" 2>/dev/null \
         && /usr/bin/jq -n --arg s "$SESSION" --arg t "$TTY" --arg x "continue" --argjson ts "$NOW" \
              '{session:$s, tty:$t, text:$x, ts:$ts}' > "$REQ" 2>/dev/null \
         && [ -s "$REQ" ]; then
        for _ in 1 2 3 4 5 6; do
          sleep 1
          [ -f "$REQ" ] || { FIRED=1; break; }
        done
        [ -n "$FIRED" ] || rm -f "$REQ"   # nobody consumed it — withdraw the request
      fi
    fi
    if [ -n "$FIRED" ]; then
      echo "$((NOW + COOLDOWN_SECS))" > "$CD"
      notify "Claude limit-wake" "Typed \"continue\" into Knave session $SHORT8 ($TTY)"
    else
      # tab gone / not mapped / handoff unconsumed — resume by hand
      notify "Claude limit-wake — resume manually" "Limits reset for session $SHORT8, but its tab wasn't found. Go press continue."
    fi
  fi
done

# -- housekeeping: drop stale map + cooldown files (tty no longer runs a claude) --
for MF in "$MAP"/*.json; do
  [ -f "$MF" ] || continue
  MTTY="$(/usr/bin/jq -r '.tty // empty' "$MF" 2>/dev/null | sed 's#/dev/##')"
  [ -n "$MTTY" ] || { rm -f "$MF"; continue; }
  ps -o tty= 2>/dev/null | tr -d ' ' | grep -qx "$MTTY" || rm -f "$MF"
done
for CF in "$SPOOL"/.cooldown-*; do
  [ -f "$CF" ] || continue
  [ "$NOW" -ge "$(cat "$CF" 2>/dev/null || echo 0)" ] && rm -f "$CF"
done
exit 0
