#!/bin/bash
# Gate 3 walkthrough on the real desk. Install the agent first, from the repo root:
#   timer-desk/install.sh --length 10 --length 1500 \
#     --cofo-desk "$PWD/.venv/bin/cofo-desk" --device 24793885-E0D3-DAA3-9DD8-4271F4793A63
# Most cases trigger the agent with signals instead of waiting for Clock: SIGUSR1 requests a
# raise, SIGUSR2 runs the scheduled lower now. Before each case: clear the desk top and keep a
# hand near the panel; any panel key stops a move.
# Writes a marker into the agent log before each case, then copies the log to probes/out/.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/Library/Logs/timer-desk.log"
SERVICE="gui/$(id -u)/dev.cofodesk.timer-desk"
mark() { printf '{"event":"case","case":"%s","time":"%s"}\n' "$1" "$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$LOG"; }
wait_enter() { read -r -p "   $1 " _ < /dev/tty; }
case_start() { echo; echo "== $1"; echo "   $2"; wait_enter "Press Enter to start."; mark "$1"; }
raise() { launchctl kill SIGUSR1 "$SERVICE"; echo "   Raise requested."; }
lower_now() { launchctl kill SIGUSR2 "$SERVICE"; echo "   Lower requested."; }

launchctl print "$SERVICE" >/dev/null 2>&1 || { echo "Agent not loaded; install it first (see the top of this script)."; exit 1; }
grep -q desk-session-ready "$LOG" || echo "Warning: the log has no desk-session-ready yet; check Bluetooth access and the phone app."
echo "Close the phone COFO app. Start with the desk at M2 (sitting)."

case_start 1-raise-and-lower "Expect: 2 cm jog up at once, 10 s pause, rise to M1. Then, when you press Enter again: 2 cm jog down, 10 s pause, back to M2."
raise
wait_enter "When the desk has reached M1, press Enter to lower."
lower_now
wait_enter "Press Enter when the desk is back at M2."

case_start 2-cancel "Expect: 2 cm jog up. Within 10 s, press any panel key (M2 is fine). The desk must not rise to M1."
raise
wait_enter "Press Enter after about 15 s."

case_start 3-adjusted "Expect: the desk rises to M1. Then press the panel down key briefly; the later lower must be skipped."
raise
wait_enter "After the rise and your down press, press Enter to request the lower."
lower_now
wait_enter "Press Enter (the desk should not have moved)."

case_start 4-already-standing "Press M1 on the panel first if the desk is low. Expect: no movement at all."
raise
wait_enter "Press Enter after about 5 s."

case_start 5-locked "Press M2 first. After the jog and pause, as soon as the rise begins, lock the screen (Ctrl-Cmd-Q). Expect: the desk stops. Unlock after."
raise
wait_enter "Press Enter after unlocking."

case_start 6-clock-latency "Press M2 first, then start a 10 s Clock timer. Expect: the jog starts within about 1 s of the timer ending, then the normal rise. Lower it yourself afterwards."
wait_enter "Press Enter when done."

mark end
mkdir -p "$DIR/out"
cp "$LOG" "$DIR/out/gate3-cases.log"
echo "Copied the log to $DIR/out/gate3-cases.log"
