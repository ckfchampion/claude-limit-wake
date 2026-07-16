#!/bin/bash
# codex-limit-wake: detector for CODEX sessions. Called by limit-wake-runner.sh
# with one rollout file per invocation: codex-limit-wake.sh <rollout.jsonl>
#
# Codex rollout logs carry structured rate-limit state — event_msg/token_count
# entries with payload.rate_limits.primary = {used_percent, window_minutes,
# resets_at(epoch)} (5h window) and .secondary (weekly). No text parsing.
# Arm rule (conservative):
#   - LAST token_count entry, its own timestamp < 15 min old, AND
#   - primary.used_percent >= 100 OR rate_limit_reached_type mentions primary
#   -> queue a wake at primary.resets_at + 120s in the shared spool.
#   - weekly/secondary-only exhaustion never arms (mirrors the Claude rule:
#     a days-out wake is worse than none).
# v1 scope: Codex sessions have no session->tty map (that hook is Claude-only),
# so the runner's fire path lands on the "resume manually" banner AT RESET —
# the win is the timing. Typed-continue for Codex needs a tty source (phase 2).
set -u
ROLLOUT="${1:-}"
[ -n "$ROLLOUT" ] && [ -f "$ROLLOUT" ] || exit 0

NOW=$(date +%s)
LAST="$(tail -n 300 "$ROLLOUT" | /usr/bin/jq -cs '
  [.[] | select(.type=="event_msg" and .payload.type=="token_count"
                and (.payload.rate_limits != null))] | last // empty' 2>/dev/null)"
[ -n "$LAST" ] || exit 0

# entry must be fresh — a stale exhausted reading must not arm days later
TS="$(printf '%s' "$LAST" | /usr/bin/jq -r '.timestamp // "1970-01-01T00:00:00Z"' \
  | sed 's/\.[0-9]*Z$/Z/')"
TSE="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" -u "$TS" +%s 2>/dev/null || echo 0)"
[ $((NOW - TSE)) -lt 900 ] || exit 0

HIT="$(printf '%s' "$LAST" | /usr/bin/jq -r '
  .payload.rate_limits as $rl
  | if (($rl.primary.used_percent // 0) >= 100)
       or (($rl.rate_limit_reached_type // "") | test("primary";"i"))
    then ($rl.primary.resets_at // 0) else 0 end')"
case "$HIT" in (""|*[!0-9]*|0) exit 0;; esac
[ "$HIT" -gt "$NOW" ] || exit 0
TARGET=$((HIT + 120))

# spool key from the rollout filename (rollout-<ts>-<uuid>.jsonl): the LAST
# uuid segment (12 hex chars) — unique enough for dedupe/cooldown keys
BASE="$(basename "$ROLLOUT" .jsonl)"
SID="codex-${BASE##*-}"
CWD="$(head -n 5 "$ROLLOUT" | /usr/bin/jq -r 'select(.type=="session_meta") | .payload.cwd // empty' 2>/dev/null | head -1)"

SPOOL="$HOME/.claude/limit-wakes"
mkdir -p "$SPOOL"
FILE="$SPOOL/${SID}.json"
CD="$SPOOL/.cooldown-${SID}"
if [ -f "$CD" ] && [ "$NOW" -lt "$(/bin/cat "$CD" 2>/dev/null || echo 0)" ]; then exit 0; fi
if [ -f "$FILE" ] && [ "$(/usr/bin/jq -r '.target // 0' "$FILE")" = "$TARGET" ]; then exit 0; fi

/usr/bin/jq -n --arg s "$SID" --arg c "$CWD" --argjson t "$TARGET" \
  '{session:$s, cwd:$c, target:$t}' > "$FILE"
FIRE_HUMAN=$(date -j -f %s "$TARGET" "+%H:%M")
NOTIFY="$HOME/.claude/scripts/claude-notify.sh"
[ -x "$NOTIFY" ] && ( "$NOTIFY" "Codex limit-wake" "Codex limit hit — reminder queued for $FIRE_HUMAN (session ${SID:6:8})" & )
exit 0
