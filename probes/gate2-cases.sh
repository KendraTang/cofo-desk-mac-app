#!/bin/bash
# Gate 2 walkthrough. Install the agent first with: timer-desk/install.sh --length 10 --length 1500
# Writes a marker into the agent log before each case, then copies the log to probes/out/.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/Library/Logs/timer-desk.log"
LABEL=dev.cofodesk.timer-desk
mark() { printf '{"event":"case","case":"%s","time":"%s"}\n' "$1" "$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$LOG"; }
step() {
    echo; echo "== $1"; echo "   Next: $2"
    read -r -p "   Press Enter first, then do it in Clock. " _ < /dev/tty
    mark "$1"
    read -r -p "   Press Enter when the case is done. " _ < /dev/tty
}

launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || { echo "Agent not loaded; run timer-desk/install.sh first."; exit 1; }

step 1-natural "Start a 10 s timer and let it finish."
step 2-other-length "Start a 20 s timer and let it finish."
step 3-pause-resume "Start a 10 s timer, pause at about 5 s, wait 10 s, resume, let it finish."
step 4-cancel "Start a 10 s timer and cancel it at about 5 s."
step 5-locked "Start a 10 s timer, lock the screen (Ctrl-Cmd-Q) right away, unlock after about 20 s."
echo; echo "== 6-restart"; echo "   Start a 30 s timer, then press Enter here; the agent restarts mid-count. Let the timer finish."
read -r -p "   Press Enter once the timer is running. " _ < /dev/tty
mark 6-restart
launchctl kickstart -k "gui/$(id -u)/$LABEL" && echo "   Agent restarted."
read -r -p "   Press Enter when the timer has finished. " _ < /dev/tty
echo
echo "Optional: case 7 needs the Mac to sleep across the end of a timer."
read -r -p "Run case 7? Type y: " answer < /dev/tty
if [ "$answer" = "y" ]; then
    step 7-sleep "Start a 1 min timer, put the Mac to sleep (Apple menu > Sleep) right away, wake it after about 2 min."
fi
mark end
mkdir -p "$DIR/out"
cp "$LOG" "$DIR/out/gate2-cases.log"
echo "Copied the log to $DIR/out/gate2-cases.log"
