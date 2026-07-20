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

# Is PID $1 alive AND still the exact child we spawned? Identity is (PID,
# lstart-at-spawn): this Mac wraps the PID space in ~25 min under churn, and
# bash auto-reaps an early-exited child, so a bare PID means nothing. A
# same-second recycle would need a full wrap in <1s. Also checks comm as
# belt-and-braces. Any doubt returns 1 (not ours) so we never signal a stranger.
child_is_ours() {  # $1=pid $2=lstart-at-spawn
  [ -n "$2" ] || return 1
  ca_comm="$(/bin/ps -p "$1" -o comm= 2>/dev/null)"
  [ -n "$ca_comm" ] || return 1
  ca_born="$(/bin/ps -p "$1" -o lstart= 2>/dev/null)"
  [ "$ca_born" = "$2" ] || return 1
  case "$ca_comm" in *terminal-notifier*) return 0 ;; *) return 1 ;; esac
}

# LIVENESS, not identity — the two must never be conflated. child_is_ours()
# answers "may I signal this?" and returns 1 on any doubt, including a failed
# ps. Treating that 1 as "the child exited" is how an earlier round of this fix
# reintroduced an unbounded hang: the caller fell through to a bare wait(),
# which blocks until the child exits — forever, if it is the hung notifier we
# are trying to bound. ps failing is most likely under exactly the process-table
# pressure this whole script guards against, so that path was live.
# kill -0 answers only "does this PID exist", which cannot fail ambiguously.
# RULE: wait() is safe ONLY once pid_alive() says the PID is gone.
pid_alive() { kill -0 "$1" 2>/dev/null; }

# Terminate a child we own and PROVE it is gone. kill(2) reports that the signal
# was DELIVERED, not that the process died, and SIGTERM is catchable — a notifier
# wedged in its runloop can ignore it outright. So: escalate TERM -> KILL, poll
# for actual disappearance after each, and wait() to collect the corpse. Returns
# 0 only when the child is provably gone; 1 if it survived even SIGKILL, so the
# caller can report a real leak instead of claiming a cleanup that never
# happened. Every signal is gated on child_is_ours, and identity doubt is
# resolved by NEITHER signalling NOR blocking — it returns 1 (unproven) so the
# caller reports honestly. Bounded by construction: no path here can block.
reap_child() {  # $1=pid $2=lstart-at-spawn
  pid_alive "$1" || { wait "$1" 2>/dev/null; return 0; }
  for reap_sig in TERM KILL; do
    # Cannot prove it is ours: refuse to signal a process we might not own, and
    # refuse to wait on one that may never exit. Unproven, and say so.
    child_is_ours "$1" "$2" || return 1
    kill -"$reap_sig" "$1" 2>/dev/null
    reap_i=0
    while [ "$reap_i" -lt 10 ]; do
      pid_alive "$1" || { wait "$1" 2>/dev/null; return 0; }
      sleep 0.2
      reap_i=$((reap_i + 1))
    done
  done
  pid_alive "$1" || { wait "$1" 2>/dev/null; return 0; }
  return 1
}

# Post through the icon notifier with a bounded lifetime. terminal-notifier 2.0
# can wait forever on a delivery callback that never fires on macOS 26 — one
# immortal PPID-1 process per banner; ~480 of them starved launchservicesd's
# 512-thread pool and panicked this Mac (2026-07-16/17/19). We stay parent of
# our own child and reap it after ~10s.
#   0 = notifier exited on its own (healthy)
#   1 = hung, and we proved it is now gone
#   2 = hung and NOT proven gone (survived SIGKILL, or identity was never
#       established so signalling it would have been unsafe) — treat as a live
#       leak; NEVER report this as cleaned up.
# EVERY invocation of $BIN goes through here; a bare call is the bug this fixes.
icon_notify() {  # $1=title $2=message
  "$BIN" -title "$1" -message "$2" >/dev/null 2>&1 &
  tn_pid=$!
  tn_born="$(/bin/ps -p "$tn_pid" -o lstart= 2>/dev/null)"
  tn_i=0
  while [ "$tn_i" -lt 20 ]; do
    pid_alive "$tn_pid" || { wait "$tn_pid" 2>/dev/null; return 0; }
    sleep 0.5
    tn_i=$((tn_i + 1))
  done
  reap_child "$tn_pid" "$tn_born" || return 2
  return 1
}

# Bounded liveness probe. The old unguarded `"$BIN" -help` was the second way
# this script could hang forever: claude-notify.sh runs from Claude Code hooks,
# so a wedged probe wedges the hook. A binary that won't answer -help in 3s is
# not usable — say so and let the caller fall back to osascript (fail-safe:
# any doubt routes to the path that provably delivers).
bin_healthy() {
  "$BIN" -help >/dev/null 2>&1 &
  probe_pid=$!
  probe_born="$(/bin/ps -p "$probe_pid" -o lstart= 2>/dev/null)"
  probe_i=0
  while [ "$probe_i" -lt 6 ]; do
    if ! pid_alive "$probe_pid"; then
      wait "$probe_pid" 2>/dev/null
      return $?
    fi
    sleep 0.5
    probe_i=$((probe_i + 1))
  done
  # Wedged. Reap it (proving the exit), then report unhealthy either way — a
  # binary that won't answer -help must not be trusted with a banner. stderr
  # suppressed: bash's "Terminated: 15" job notice would otherwise surface on
  # the calling hook's stderr and read like a failure, when it is this watchdog
  # working as designed.
  reap_child "$probe_pid" "$probe_born" 2>/dev/null
  return 1
}

case "${1:-}" in
  --test-icon)
    [ -x "$BIN" ] || { echo "no icon notifier at $BIN"; exit 1; }
    # stderr suppressed: the only thing the function writes there is bash's job
    # notice ("Terminated: 15") when the watchdog reaps — noise that would land
    # above the verdict below and read like an error. All findings go to stdout.
    icon_notify "Claude" "Icon test — if you can SEE this banner (Claude icon), run: claude-notify.sh --trust-icon" 2>/dev/null
    case $? in
      0) echo "posted. Saw the Claude-icon banner? Then run: $0 --trust-icon" ;;
      1) echo "posted, but the notifier hung and had to be killed — confirmed gone."
         echo "A hang means its delivery callback never fired, so the banner most"
         echo "likely went nowhere. Do NOT run --trust-icon unless you SAW it." ;;
      *) echo "WARNING: the notifier hung and could NOT be confirmed dead —"
         echo "it either survived SIGKILL or could not be positively identified,"
         echo "so it was left alone rather than risk signalling another process."
         echo "Assume a process leaked. Do NOT run --trust-icon."
         echo "Check for strays:  pgrep -fl ClaudeNotify.app"
         echo "Leaked notifiers are what panicked this Mac (see README)." ;;
    esac
    exit 0;;
  --trust-icon)
    touch "$MARKER"
    echo "icon path trusted — banners now post via ClaudeNotify.app"
    exit 0;;
esac

TITLE="${1:-Claude}"; MSG="${2:-}"
if [ -f "$MARKER" ] && [ -x "$BIN" ] && bin_healthy; then
  # Backgrounded so a hook never blocks on the banner; icon_notify bounds the
  # child's lifetime inside that subshell.
  ( icon_notify "$TITLE" "$MSG" ) >/dev/null 2>&1 &
else
  # argv-passing form: a payload containing quotes must not become an
  # AppleScript syntax error (the runner's own message quotes "continue").
  ( /usr/bin/osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$TITLE" "$MSG" 2>/dev/null & )
fi
exit 0
