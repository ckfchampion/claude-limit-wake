#!/bin/bash
# Offline test suite for claude-limit-wake. Runs every script against a
# throwaway $HOME with stubbed notifier + injector: no banners are posted, no
# Terminal is driven, nothing under the real ~/.claude is touched.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
S="$HOME/.claude/scripts"; SPOOL="$HOME/.claude/limit-wakes"; MAP="$HOME/.claude/session-ttys"
mkdir -p "$S" "$HOME/.claude/projects/proj" "$HOME/.codex/sessions" "$SPOOL" "$MAP"
cp "$ROOT"/scripts/* "$S/"
cat > "$S/claude-notify.sh" <<'STUB'
#!/bin/bash
printf '%s\t%s\n' "$1" "$2" >> "$HOME/.claude/notify.log"
STUB
cat > "$S/claude-inject.sh" <<'STUB'
#!/bin/bash
printf '%s\t%s\n' "$1" "${2:-}" >> "$HOME/.claude/inject.log"
exit "${INJECT_RC:-0}"
STUB
chmod +x "$S"/*

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1${2:+ — $2}"; }
check() { if eval "$2"; then ok "$1"; else fail "$1" "${3:-}"; fi; }
reset_state() { rm -rf "$SPOOL" "$MAP" "$HOME/.claude/notify.log" "$HOME/.claude/inject.log" "$HOME/.knave"; mkdir -p "$SPOOL" "$MAP"; }
notify_log() { sleep 0.3; cat "$HOME/.claude/notify.log" 2>/dev/null; }
NOW=$(date +%s)
iso_ago() { date -u -v-"$1"S +%Y-%m-%dT%H:%M:%S.000Z; }

# --- fixtures --------------------------------------------------------------
# 429 transcript entry exactly as the CLI writes it (synthetic assistant msg)
entry_429() {  # $1 sid  $2 text  $3 seconds-ago
  jq -nc --arg s "$1" --arg t "$2" --arg ts "$(iso_ago "$3")" \
    '{type:"assistant",isApiErrorMessage:true,error:"rate_limit",apiErrorStatus:429,
      timestamp:$ts,sessionId:$s,cwd:"/work",message:{role:"assistant",content:[{type:"text",text:$t}]}}'
}
entry_plain() {  # ordinary assistant message quoting banner text — must never arm
  jq -nc --arg s "$1" --arg t "$2" --arg ts "$(iso_ago 5)" \
    '{type:"assistant",timestamp:$ts,sessionId:$s,cwd:"/work",message:{role:"assistant",content:[{type:"text",text:$t}]}}'
}
run_detector() {  # $1 sid $2 transcript
  jq -nc --arg s "$1" --arg t "$2" '{session_id:$s,transcript_path:$t,cwd:"/work"}' | "$S/limit-wake.sh"
}
expected_target() {  # $1 HH:MM (24h) -> epoch the detector should queue
  local t; t=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) $1:00" +%s)
  [ "$t" -le "$NOW" ] && t=$((t+86400)); echo $((t+120))
}
codex_rollout() {  # $1 file $2 primary% $3 secondary% $4 resets_at $5 seconds-ago
  { jq -nc '{type:"session_meta",payload:{cwd:"/codex-work"}}'
    jq -nc --argjson p "$2" --argjson s "$3" --argjson r "$4" --arg ts "$(iso_ago "$5")" \
      '{type:"event_msg",timestamp:$ts,payload:{type:"token_count",
        rate_limits:{primary:{used_percent:$p,window_minutes:300,resets_at:$r},
                     secondary:{used_percent:$s,window_minutes:10080,resets_at:($r+500000)}}}}'
  } > "$1"
}

echo "== syntax"
for f in "$ROOT"/scripts/*.sh "$ROOT"/install.sh "$ROOT"/tests/run.sh; do
  check "bash -n $(basename "$f")" "bash -n '$f'"
done
check "plist template lints" "sed 's|__HOME__|$HOME|g' '$ROOT'/launchagent/*.plist.template > '$TMP/agent.plist' && plutil -lint '$TMP/agent.plist' >/dev/null"

echo "== detector: limit-wake.sh"
reset_state; T="$HOME/.claude/projects/proj/a.jsonl"; SID="sess-aaaa1111-2222"
entry_429 "$SID" "You've hit your usage limit · resets 3pm" 5 > "$T"
echo '{"type":"summary","summary":"metadata appended after the 429"}' >> "$T"
run_detector "$SID" "$T" >/dev/null
check "arms on a real 429 ('resets 3pm')" "[ -f '$SPOOL/$SID.json' ]"
check "target = 15:00 local + 120s" "[ \"\$(jq -r .target '$SPOOL/$SID.json')\" = '$(expected_target 15:00)' ]"
check "spool carries session + cwd" "[ \"\$(jq -r '.session+\" \"+.cwd' '$SPOOL/$SID.json')\" = '$SID /work' ]"
check "posts the 'wake queued' banner" "notify_log | grep -q 'auto-wake queued'"
run_detector "$SID" "$T" >/dev/null
check "same target twice -> one banner (dedupe)" "[ \"\$(notify_log | wc -l | tr -d ' ')\" = 1 ]"

reset_state; entry_429 "$SID" "Limit reached · resets 12:30am" 5 > "$T"; run_detector "$SID" "$T" >/dev/null
check "12:30am parses to 00:30" "[ \"\$(jq -r .target '$SPOOL/$SID.json')\" = '$(expected_target 00:30)' ]"
reset_state; entry_429 "$SID" "Limit reached · resets 12pm" 5 > "$T"; run_detector "$SID" "$T" >/dev/null
check "12pm parses to 12:00" "[ \"\$(jq -r .target '$SPOOL/$SID.json')\" = '$(expected_target 12:00)' ]"

reset_state; entry_plain "$SID" "the banner said: limit reached · resets 3pm" > "$T"; run_detector "$SID" "$T" >/dev/null
check "quoted banner text in a normal message never arms" "[ ! -f '$SPOOL/$SID.json' ]"
reset_state; entry_429 "$SID" "Weekly limit reached · resets Thursday 3pm" 5 > "$T"; run_detector "$SID" "$T" >/dev/null
check "weekly limit (names a weekday) never arms" "[ ! -f '$SPOOL/$SID.json' ]"
reset_state; entry_429 "$SID" "Limit reached · resets 3pm" 1200 > "$T"; run_detector "$SID" "$T" >/dev/null
check "stale 429 entry (>15 min) never arms" "[ ! -f '$SPOOL/$SID.json' ]"
reset_state; entry_429 "$SID" "Limit reached, please try again later" 5 > "$T"; run_detector "$SID" "$T" >/dev/null
check "no parseable time -> no wake" "[ ! -f '$SPOOL/$SID.json' ]"
reset_state; echo $((NOW+600)) > "$SPOOL/.cooldown-$SID"
entry_429 "$SID" "Limit reached · resets 3pm" 5 > "$T"; run_detector "$SID" "$T" >/dev/null
check "active cooldown blocks re-arm" "[ ! -f '$SPOOL/$SID.json' ]"
reset_state; echo '{"session_id":"x"}' | "$S/limit-wake.sh" >/dev/null
check "missing transcript -> quiet exit 0" "[ \$? -eq 0 ] && [ -z \"\$(ls '$SPOOL')\" ]"

echo "== detector: codex-limit-wake.sh"
reset_state; R="$HOME/.codex/sessions/rollout-2026-08-28T10-00-00-abcdef123456.jsonl"
codex_rollout "$R" 100 40 $((NOW+3600)) 5; "$S/codex-limit-wake.sh" "$R"
check "primary exhausted -> arms at resets_at+120" "[ \"\$(jq -r .target '$SPOOL/codex-abcdef123456.json')\" = '$((NOW+3720))' ]"
check "spool key = codex-<uuid tail>, cwd from session_meta" "[ \"\$(jq -r '.session+\" \"+.cwd' '$SPOOL/codex-abcdef123456.json')\" = 'codex-abcdef123456 /codex-work' ]"
check "posts the Codex reminder banner" "notify_log | grep -q 'Codex limit hit'"
reset_state; codex_rollout "$R" 40 100 $((NOW+3600)) 5; "$S/codex-limit-wake.sh" "$R"
check "weekly/secondary-only exhaustion never arms" "[ ! -f '$SPOOL/codex-abcdef123456.json' ]"
reset_state; codex_rollout "$R" 100 40 $((NOW+3600)) 1200; "$S/codex-limit-wake.sh" "$R"
check "stale token_count entry never arms" "[ ! -f '$SPOOL/codex-abcdef123456.json' ]"
reset_state; codex_rollout "$R" 100 40 $((NOW-60)) 5; "$S/codex-limit-wake.sh" "$R"
check "resets_at in the past never arms" "[ ! -f '$SPOOL/codex-abcdef123456.json' ]"

echo "== runner: limit-wake-runner.sh"
queue() { jq -n --arg s "$1" --argjson t "$2" '{session:$s,cwd:"/work",target:$t}' > "$SPOOL/$1.json"; }
map()   { jq -n --arg t "$2" '{tty:$t,cwd:"/work",recorded:0}' > "$MAP/$1.json"; }
reset_state; queue sess-due $((NOW-30)); map sess-due /dev/ttys099; "$S/limit-wake-runner.sh"
check "heartbeat stamped" "[ -f '$SPOOL/.last-run' ]"
check "due wake types 'continue' into the mapped tty" "grep -q '^/dev/ttys099	continue$' '$HOME/.claude/inject.log'"
check "fired wake is consumed" "[ ! -f '$SPOOL/sess-due.json' ]"
check "cooldown written after a successful fire" "[ -f '$SPOOL/.cooldown-sess-due' ]"
check "banner reports the typed continue" "notify_log | grep -q 'Typed \"continue\"'"

reset_state; queue sess-later $((NOW+600)); map sess-later /dev/ttys098; "$S/limit-wake-runner.sh"
check "not-yet-due wake is left queued" "[ -f '$SPOOL/sess-later.json' ]"
check "nothing injected for a future wake" "[ ! -f '$HOME/.claude/inject.log' ]"

reset_state; queue sess-gone $((NOW-30)); map sess-gone /dev/ttys097; INJECT_RC=3 "$S/limit-wake-runner.sh"
check "inject failure -> 'resume manually' banner" "notify_log | grep -q 'resume manually'"
check "no cooldown when nothing was typed" "[ ! -f '$SPOOL/.cooldown-sess-gone' ]"
check "failed wake still consumed (no re-fire loop)" "[ ! -f '$SPOOL/sess-gone.json' ]"

reset_state; queue sess-nomap $((NOW-30)); "$S/limit-wake-runner.sh"
check "unmapped session -> manual banner, no inject" "notify_log | grep -q 'resume manually' && [ ! -f '$HOME/.claude/inject.log' ]"

reset_state; queue sess-emb $((NOW-30)); map sess-emb /dev/ttys096; INJECT_RC=4 "$S/limit-wake-runner.sh"
check "exit 4 with no host app -> request withdrawn + manual banner" "[ ! -f '$HOME/.knave/limit-wake-fire/ttys096.json' ] && notify_log | grep -q 'resume manually'"

reset_state; queue sess-cool $((NOW-30)); map sess-cool /dev/ttys095; echo $((NOW+600)) > "$SPOOL/.cooldown-sess-cool"; "$S/limit-wake-runner.sh"
check "cooldown suppresses firing" "[ ! -f '$HOME/.claude/inject.log' ] && [ ! -f '$SPOOL/sess-cool.json' ]"

reset_state; echo '{"target":"garbage"}' > "$SPOOL/bad.json"; "$S/limit-wake-runner.sh"
check "corrupt spool file is dropped" "[ ! -f '$SPOOL/bad.json' ]"

reset_state; T2="$HOME/.claude/projects/proj/scan.jsonl"; SID2="sess-scan-0000"
entry_429 "$SID2" "Limit reached · resets 3pm" 5 > "$T2"; "$S/limit-wake-runner.sh"
check "60s scan queues a wake from a fresh transcript 429" "[ -f '$SPOOL/$SID2.json' ]"
reset_state; mkdir -p "$HOME/.claude/projects/proj/subagents"; entry_429 sub-1 "resets 3pm" 5 > "$HOME/.claude/projects/proj/subagents/s.jsonl"; "$S/limit-wake-runner.sh"
check "subagent transcripts are not scanned" "[ ! -f '$SPOOL/sub-1.json' ]"
reset_state; echo $((NOW-5)) > "$SPOOL/.cooldown-old"; "$S/limit-wake-runner.sh"
check "expired cooldown files are swept" "[ ! -f '$SPOOL/.cooldown-old' ]"

echo "== inject guard: claude-inject.sh (real script, never reaches Terminal)"
"$ROOT/scripts/claude-inject.sh" not-a-tty >/dev/null 2>&1; check "bad tty arg -> exit 2" "[ $? -eq 2 ]"
FREE=""; for n in 999 998 997 996; do ps -o tty= 2>/dev/null | grep -q "ttys$n" || { FREE="ttys$n"; break; }; done
"$ROOT/scripts/claude-inject.sh" "/dev/$FREE" >/dev/null 2>&1; check "no claude on tty -> exit 3 (guard refuses)" "[ $? -eq 3 ]"

echo "== session-tty-hook.sh"
echo '{"session_id":"hook-1","cwd":"/work"}' | "$S/session-tty-hook.sh"; RC=$?
check "exits 0" "[ $RC -eq 0 ]"
if [ -f "$MAP/hook-1.json" ]; then check "recorded tty is a /dev/ttys*" "jq -r .tty '$MAP/hook-1.json' | grep -q '^/dev/ttys'"; else echo "  skip no controlling tty in this environment (CI)"; fi
echo '{}' | "$S/session-tty-hook.sh"; check "no session_id -> no map file" "[ ! -f '$MAP/.json' ]"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
