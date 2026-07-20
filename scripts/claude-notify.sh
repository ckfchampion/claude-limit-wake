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

# Post through the icon notifier with a bounded lifetime. terminal-notifier 2.0
# can wait forever on a delivery callback that never fires on macOS 26 — one
# immortal PPID-1 process per banner; ~480 of them starved launchservicesd's
# 512-thread pool and panicked this Mac (2026-07-16/17/19). We stay parent of
# our own child and reap it after ~10s. bash auto-reaps an early-exited child
# and this Mac wraps the PID space in ~25 min under churn, so the kill requires
# an exact (PID, lstart) identity match — fail-closed, a recycled PID is never
# signaled. Returns 0 if the notifier exited on its own, 1 if it had to be
# reaped (which means the delivery callback never fired — see --test-icon).
# EVERY invocation of $BIN goes through here; a bare call is the bug this fixes.
icon_notify() {  # $1=title $2=message
  "$BIN" -title "$1" -message "$2" >/dev/null 2>&1 &
  tn_pid=$!
  tn_born="$(/bin/ps -p "$tn_pid" -o lstart= 2>/dev/null)"
  tn_i=0
  while [ "$tn_i" -lt 20 ]; do
    kill -0 "$tn_pid" 2>/dev/null || return 0
    sleep 0.5
    tn_i=$((tn_i + 1))
  done
  tn_comm="$(/bin/ps -p "$tn_pid" -o comm= 2>/dev/null)"
  tn_now="$(/bin/ps -p "$tn_pid" -o lstart= 2>/dev/null)"
  case "$tn_comm" in
    *terminal-notifier*)
      [ -n "$tn_born" ] && [ "$tn_now" = "$tn_born" ] && kill "$tn_pid" 2>/dev/null ;;
  esac
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
    if ! kill -0 "$probe_pid" 2>/dev/null; then
      wait "$probe_pid" 2>/dev/null
      return $?
    fi
    sleep 0.5
    probe_i=$((probe_i + 1))
  done
  probe_comm="$(/bin/ps -p "$probe_pid" -o comm= 2>/dev/null)"
  probe_now="$(/bin/ps -p "$probe_pid" -o lstart= 2>/dev/null)"
  case "$probe_comm" in
    *terminal-notifier*)
      [ -n "$probe_born" ] && [ "$probe_now" = "$probe_born" ] && kill "$probe_pid" 2>/dev/null ;;
  esac
  return 1
}

case "${1:-}" in
  --test-icon)
    [ -x "$BIN" ] || { echo "no icon notifier at $BIN"; exit 1; }
    if icon_notify "Claude" "Icon test — if you can SEE this banner (Claude icon), run: claude-notify.sh --trust-icon"; then
      echo "posted. Saw the Claude-icon banner? Then run: $0 --trust-icon"
    else
      echo "posted, but the notifier hung and was reaped after 10s."
      echo "That means its delivery callback never fired — the banner most"
      echo "likely went nowhere. Do NOT run --trust-icon unless you SAW it."
    fi
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
