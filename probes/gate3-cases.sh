#!/bin/bash
# Written for the agent before the sit and stand cycle (2026-10-31): SIGUSR2 is gone and SIGUSR1 now only
# makes the countdown due. Kept as the record of how Gate 3 ran; see cycle-cases.sh.
# Gate 3 walkthrough on the real desk. Rebuilds and reinstalls the agent (with desk tracing),
# waits for its desk connection, then runs the cases. Run it from a regular terminal, not tmux,
# so codesign can reach the keychain.
# Most cases trigger the agent with signals instead of waiting for Clock: SIGUSR1 requests a
# raise, SIGUSR2 runs the scheduled lower now. Before each case: clear the desk top and keep a
# hand near the panel; any panel key stops a move.
# Writes a marker into the agent log before each case, then copies the log to probes/out/.
# Usage: gate3-cases.sh [CASE...]   e.g. gate3-cases.sh 3 4 (default: all six)
set -u
CASES="$*"
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/Library/Logs/timer-desk.log"
SERVICE="gui/$(id -u)/dev.cofodesk.timer-desk"
mark() { printf '{"event":"case","case":"%s","time":"%s"}\n' "$1" "$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$LOG"; }
wait_enter() { read -r -p "   $1 " _ < /dev/tty; }
case_start() { echo; echo "== $1"; echo "   $2"; wait_enter "Press Enter to start."; mark "$1"; }
raise() { launchctl kill SIGUSR1 "$SERVICE"; echo "   Raise requested."; }
lower_now() { launchctl kill SIGUSR2 "$SERVICE"; echo "   Lower requested."; }

echo "Close the phone COFO app. Start with the desk at M2 (sitting)."
wait_enter "Press Enter to rebuild and reinstall the agent."
REPO="$(cd "$DIR/.." && pwd)"
LINES=$(wc -l < "$LOG" 2>/dev/null || echo 0)
"$REPO/timer-desk/install.sh" --length 10 --length 1500 --trace-desk \
    --cofo-desk "$REPO/.venv/bin/cofo-desk" --device 24793885-E0D3-DAA3-9DD8-4271F4793A63 || exit 1
echo "Waiting up to 30 s for the desk connection..."
for _ in $(seq 30); do
    tail -n +$((LINES + 1)) "$LOG" | grep -q desk-session-ready && break
    sleep 1
done
if ! tail -n +$((LINES + 1)) "$LOG" | grep -q desk-session-ready; then
    echo "The agent did not connect to the desk. Stopping here; recent log:"
    tail -n +$((LINES + 1)) "$LOG" | grep -v TRACE | tail -5
    exit 1
fi
echo "Connected."

case1() {
    case_start 1-raise-and-lower "Expect: 2 cm jog up at once, 10 s pause, rise to M1. Then, when you press Enter again: 2 cm jog down, 10 s pause, back to M2."
    raise
    wait_enter "When the desk has reached M1, press Enter to lower."
    lower_now
    wait_enter "Press Enter when the desk is back at M2."
}
case2() {
    case_start 2-cancel "Expect: 2 cm jog up. Within 10 s, press any panel key (M2 is fine). The desk must not rise to M1."
    raise
    wait_enter "Press Enter after about 15 s."
}
case3() {
    case_start 3-adjusted "Expect: the desk rises to M1. Then tap the panel down key once; the lower must be skipped."
    raise
    wait_enter "After the rise and your tap, press Enter to request the lower."
    lower_now
    wait_enter "Press Enter after about 5 s (the desk should not have moved)."
}
case4() {
    case_start 4-already-standing "Press M1 on the panel first if the desk is low, and wait until it stops. Expect: no movement at all."
    wait_enter "Press Enter once the desk is high and still."
    raise
    wait_enter "Press Enter after about 5 s."
}
case5() {
    case_start 5-locked "Press M2 first. After the jog and pause, as soon as the rise begins, lock the screen (Ctrl-Cmd-Q). Expect: the desk stops. Unlock after."
    raise
    wait_enter "Press Enter after unlocking."
}
case6() {
    case_start 6-clock-latency "Press M2 first and wait until it stops. Then start a 10 s Clock timer and do not touch the panel. Expect: the jog starts within about 1 s of the timer ending, then the normal rise."
    wait_enter "Press Enter when the desk has risen to M1."
}

for n in ${CASES:-1 2 3 4 5 6}; do "case$n"; done

mark end
mkdir -p "$DIR/out"
cp "$LOG" "$DIR/out/gate3-cases.log"
echo "Copied the log to $DIR/out/gate3-cases.log"
