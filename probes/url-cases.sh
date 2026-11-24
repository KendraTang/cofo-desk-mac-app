#!/bin/bash
# Reinstalls TimerDesk.app, then moves the real desk through the URL scheme: stand, stop after 2 s,
# sit, stop, a wiggle, then an unknown command that must be ignored. Run it in a plain terminal (not tmux).
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HOME/Library/Logs/timer-desk.log"

"$REPO/timer-desk/install.sh"
START=$(wc -l < "$LOG")
echo "Waiting for the desk to connect..."
for _ in $(seq 60); do
    tail -n +$((START + 1)) "$LOG" | grep -q '"desk-session-ready"' && break
    sleep 1
done

step() {
    echo "== open $1"
    open "$1"
    sleep "$2"
}
step "timerdesk://stand" 2
step "timerdesk://stop" 3
step "timerdesk://sit" 2
step "timerdesk://stop" 3
step "timerdesk://wiggle" 10
step "timerdesk://bogus" 1

echo "== log"
tail -n +$((START + 1)) "$LOG" | grep -E '"(desk-session-ready|manual-move[a-z-]*|wiggle|url-ignored)"'
