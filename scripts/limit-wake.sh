#!/bin/bash
# limit-wake (detector half): fired by Stop/SubagentStop, and re-used by
# limit-wake-runner.sh's cron-side scan (same JSON payload on stdin). If the
# just-ended turn hit a rate limit, queue a wake request in the spool dir.
# The ClaudeLimitWake cron job (limit-wake-runner.sh) fires due wakes.
# One spool file per session (overwritten) — no per-alarm jobs.
#
# NOTE (2026-07-11): a limit-aborted turn fires NO Stop/SubagentStop hook in a
# session without live subagents — the hooks are only the fast path; the
# runner's per-minute transcript scan is the path that reliably catches a hit.

set -u
notify() {  # title, message — route through claude-notify.sh: osascript banner
  # by default (proven to deliver); the Claude-icon app is used only once a
  # human has verified it on screen (see claude-notify.sh --test-icon).
  N="$HOME/.claude/scripts/claude-notify.sh"
  if [ -x "$N" ]; then
    ( "$N" "$1" "$2" >/dev/null 2>&1 & )
  else
    # argv-passing form: a payload containing quotes must not become an
    # AppleScript syntax error (the runner's own message quotes "continue").
    /usr/bin/osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$1" "$2" 2>/dev/null
  fi
}

PAYLOAD="$(cat)"
SESSION_ID="$(printf '%s' "$PAYLOAD" | /usr/bin/jq -r '.session_id // empty')"
TRANSCRIPT="$(printf '%s' "$PAYLOAD" | /usr/bin/jq -r '.transcript_path // empty')"
CWD="$(printf '%s' "$PAYLOAD" | /usr/bin/jq -r '.cwd // empty')"
[ -n "$SESSION_ID" ] && [ -f "$TRANSCRIPT" ] || exit 0

# A REAL limit hit is a synthetic assistant entry the CLI flags itself:
# isApiErrorMessage=true + error="rate_limit" (+ apiErrorStatus 429). Never
# grep raw transcript text — quoted banner text in an ordinary user/assistant
# message must never arm a wake (bit us 2026-07-11).
# Freshness comes from the ENTRY's own timestamp (<15 min), not its position:
# the CLI appends session metadata lines (ai-title, last-prompt, pr-link, …)
# after the 429 entry, so "last N lines" alone misses real hits.
NOW=$(date +%s)
TXT="$(tail -n 200 "$TRANSCRIPT" | /usr/bin/jq -r --argjson now "$NOW" \
  'select(.isApiErrorMessage == true and .error == "rate_limit")
   | select((((.timestamp // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+"; "") | fromdateiso8601) as $ts | ($now - $ts) < 900))
   | .message.content[]? | select(.type == "text") | .text' 2>/dev/null | tail -1)"
[ -n "$TXT" ] || exit 0
printf '%s' "$TXT" | grep -qiE 'resets|try again' || exit 0
# Weekly-style limits name a weekday; a partial parse must NEVER arm a wake.
printf '%s' "$TXT" | grep -qiE '(mon|tues|wednes|thurs|fri|satur|sun)day' && exit 0

TIMESTR="$(printf '%s' "$TXT" | grep -oiE '[0-9]{1,2}(:[0-9]{2})? ?[ap]m' | tail -1)"
[ -n "$TIMESTR" ] || exit 0
HOUR="$(printf '%s' "$TIMESTR" | grep -oE '^[0-9]{1,2}')"
MIN="$(printf '%s' "$TIMESTR" | grep -oE ':[0-9]{2}' | tr -d ':')"; MIN="${MIN:-00}"
AMPM="$(printf '%s' "$TIMESTR" | grep -oiE '[ap]m' | tr '[:upper:]' '[:lower:]')"
case "$HOUR" in (""|*[!0-9]*) exit 0;; esac
case "$MIN"  in (*[!0-9]*) exit 0;; esac
[ "$AMPM" = "am" ] || [ "$AMPM" = "pm" ] || exit 0
[ "$HOUR" -ge 1 ] && [ "$HOUR" -le 12 ] || exit 0
[ "$AMPM" = "pm" ] && [ "$HOUR" -ne 12 ] && HOUR=$((HOUR + 12))
[ "$AMPM" = "am" ] && [ "$HOUR" -eq 12 ] && HOUR=0

# Seconds pinned to :00 — BSD date fills unspecified fields from "now", which
# made the same reset time parse to different epochs and broke the dedupe.
TARGET="$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) $(printf '%02d:%02d:00' "$HOUR" "$MIN")" +%s 2>/dev/null)"
case "$TARGET" in (""|*[!0-9]*) exit 0;; esac
[ "$TARGET" -le "$NOW" ] && TARGET=$((TARGET + 86400))
TARGET=$((TARGET + 120))

SPOOL="$HOME/.claude/limit-wakes"
mkdir -p "$SPOOL"
FILE="$SPOOL/${SESSION_ID}.json"
# Loop-guard: if we auto-continued this session within the cooldown window, do
# NOT re-arm — an injected "continue" that itself re-hit the limit must not spin
# (a re-fire loop seen 2026-07-12). The re-limit is visible in the live tab.
CD="$SPOOL/.cooldown-${SESSION_ID}"
if [ -f "$CD" ] && [ "$NOW" -lt "$(/bin/cat "$CD" 2>/dev/null || echo 0)" ]; then exit 0; fi
# Same target already queued for this session -> quiet no-op.
if [ -f "$FILE" ] && [ "$(/usr/bin/jq -r '.target // 0' "$FILE")" = "$TARGET" ]; then exit 0; fi

/usr/bin/jq -n --arg s "$SESSION_ID" --arg c "$CWD" --argjson t "$TARGET" \
  '{session:$s, cwd:$c, target:$t}' > "$FILE"

FIRE_HUMAN=$(date -j -f %s "$TARGET" "+%H:%M")
notify "Claude limit-wake" "Limit hit — auto-wake queued for $FIRE_HUMAN (session ${SESSION_ID:0:8})"
printf '{"systemMessage":"⏰ limit-wake queued: session %s auto-resumes at %s"}\n' "${SESSION_ID:0:8}" "$FIRE_HUMAN"
exit 0
