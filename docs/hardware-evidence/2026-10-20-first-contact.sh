#!/bin/bash
# First real-desk check. Steps 1-3 never move the desk; 4 and 5 move about 0.1 s each, only after you type y.
set -u
REPO=/Users/tkain/projects/cofo-desk-auto
DEVICE='24793885-E0D3-DAA3-9DD8-4271F4793A63'
LOG="$(dirname "$0")/desk-check.log"
CLI=("$REPO/.venv/bin/cofo-desk" --json --trace --device "$DEVICE")

: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

step() { echo; echo "===== $1 ($(date '+%H:%M:%S'))"; }
run() { echo "\$ cofo-desk $*"; "${CLI[@]}" "$@"; local rc=$?; echo "rc=$rc"; return $rc; }
ask() { local answer; read -r -p "$1 " answer < /dev/tty; echo "ANSWER[$1] $answer"; REPLY_TEXT=$answer; }

step "1. GATT structure (read only)"
run inspect || { echo "Cannot inspect; stopping."; exit 1; }

step "2. Status: subscribe, login, height/limit queries (no movement)"
run status || { echo "Status failed; stopping before any movement."; exit 1; }
ask "What height does the desk panel show right now (e.g. 72.0)?"

step "3. Standalone stop: STOP, login, STOP (no movement)"
run stop || { echo "Stop failed; stopping before any movement."; exit 1; }

step "4. Optional: jog UP for 0.1 s (expected a few mm; keep a hand on the panel)"
ask "Type y to move UP about 0.1 s, anything else to finish:"
if [ "$REPLY_TEXT" = "y" ]; then
    run up --seconds 0.1
    run status
    ask "Panel height now?"

    step "5. Optional: jog DOWN for 0.1 s to return"
    ask "Type y to move DOWN about 0.1 s, anything else to finish:"
    if [ "$REPLY_TEXT" = "y" ]; then
        run down --seconds 0.1
        run status
        ask "Panel height now?"
    fi
fi

step "Done"
echo "Log saved to $LOG"
