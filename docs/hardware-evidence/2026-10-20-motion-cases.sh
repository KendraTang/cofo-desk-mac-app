#!/bin/bash
# Three one-off real-desk cases. Every movement step asks first; type anything but y to skip it.
# Keep a hand on the panel. Distances are upper bounds at about 3 cm/s.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO=/Users/tkain/projects/cofo-desk-auto
PY="$REPO/.venv/bin/python"
DEVICE='24793885-E0D3-DAA3-9DD8-4271F4793A63'
LOG="$DIR/2026-10-20-motion-cases.log"

: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

step() { echo; echo "===== $1 ($(date '+%H:%M:%S'))"; }
ask() { local answer; read -r -p "$1 " answer < /dev/tty; echo "ANSWER[$1] $answer"; REPLY_TEXT=$answer; }
probe() { echo "\$ probe $*"; "$PY" "$DIR/2026-10-20-motion-probe.py" "$@"; echo "rc=$?"; }
panel() { ask "Panel height now?"; }

step "0. Status (no movement)"
"$REPO/.venv/bin/cofo-desk" --json --device "$DEVICE" status || { echo "Status failed; stopping."; exit 1; }
panel

step "1a. STOP while moving: jog UP 1 s, then listen 2 s (about 3 cm)"
ask "Type y to run 1a:"
if [ "$REPLY_TEXT" = "y" ]; then probe jog --seconds 1 --listen 2; panel; fi

step "1b. STOP on a signal: start UP 3 s, SIGTERM 1 s after the first UP write (about 3 cm)"
ask "Type y to run 1b:"
if [ "$REPLY_TEXT" = "y" ]; then
    OUT="$DIR/2026-10-20-motion-1b.out"
    "$REPO/.venv/bin/cofo-desk" --json --trace --device "$DEVICE" up --seconds 3 > "$OUT" 2>&1 &
    PID=$!
    for _ in $(seq 100); do grep -q 'write .* f1f10100017e' "$OUT" && break; sleep 0.1; done
    sleep 1
    echo "sending SIGTERM at $(date '+%H:%M:%S')"
    kill -TERM "$PID"
    wait "$PID"; echo "cli rc=$? (143 expected)"
    cat "$OUT"
    probe listen --listen 1.5
    panel
fi

step "2. goto target unit: current + 5 mm, 1 s timeout (at most about 3 cm)"
ask "Type y to run 2:"
if [ "$REPLY_TEXT" = "y" ]; then probe goto --offset 5 --timeout 1 --listen 2; panel; fi

step "3. No resend: ONE UP, guard STOP after 2 s unless the desk stops itself (at most about 6 cm)"
ask "Type y to run 3:"
if [ "$REPLY_TEXT" = "y" ]; then probe single --guard 2 --listen 2; panel; fi

step "4. Return: jog DOWN up to 6 s, stops 1 mm above the lower limit"
ask "Type y to go back down:"
if [ "$REPLY_TEXT" = "y" ]; then probe jog --direction down --seconds 6 --listen 1; panel; fi

step "Done"
echo "Log saved to $LOG"
