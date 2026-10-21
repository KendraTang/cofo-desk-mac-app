#!/bin/bash
# Gate 3 walkthrough on the real desk. Install the agent first with:
#   timer-desk/install.sh --length 10 --length 1500 --lower-after 60 \
#     --cofo-desk "$PWD/.venv/bin/cofo-desk" --device 24793885-E0D3-DAA3-9DD8-4271F4793A63
# Before each case: clear the desk top and keep a hand near the panel. Any panel key stops a move.
# Writes a marker into the agent log before each case, then copies the log to probes/out/.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/Library/Logs/timer-desk.log"
LABEL=dev.cofodesk.timer-desk
mark() { printf '{"event":"case","case":"%s","time":"%s"}\n' "$1" "$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$LOG"; }
step() {
    echo; echo "== $1"; echo "   Next: $2"
    read -r -p "   Press Enter first, then do it. " _ < /dev/tty
    mark "$1"
    read -r -p "   Press Enter when the case is done. " _ < /dev/tty
}

launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || { echo "Agent not loaded; install it first (see the top of this script)."; exit 1; }
echo "Close the phone COFO app so it does not hold the desk connection. Start with the desk at M2 (sitting)."

step 1-raise-and-lower "Start a 10 s timer. Expect: a 2 cm jog up, 10 s pause, rise to M1. About 60 s later: a 2 cm jog down, 10 s pause, back to M2. Wait for all of it."
step 2-cancel "Start a 10 s timer. After the jog up, briefly press a panel key (down is fine) within 10 s. Expect: no rise."
step 3-adjusted "Press M2 if needed, then start a 10 s timer and let the desk rise. Within 60 s, press the panel down key briefly. Expect: no automatic lower."
step 4-already-standing "With the desk still high (press M1 if needed), start a 10 s timer. Expect: no movement."
step 5-locked "Press M2, start a 10 s timer; as soon as the rise to M1 begins, lock the screen (Ctrl-Cmd-Q). Expect: the desk stops. Unlock after."
mark end
mkdir -p "$DIR/out"
cp "$LOG" "$DIR/out/gate3-cases.log"
echo "Copied the log to $DIR/out/gate3-cases.log"
