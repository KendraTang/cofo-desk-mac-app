#!/bin/bash
# Short walkthrough of the sit and stand cycle on the real desk, then back to the daily setup.
# Installs the agent with short countdowns, so the desk moves within a minute. Run it from a regular
# terminal, not tmux, so codesign can reach the keychain. Clear the desk top first; any panel key
# stops a move. Writes a marker into the agent log before each case, then copies the log to probes/out/.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
LOG="$HOME/Library/Logs/timer-desk.log"
DESK=(--cofo-desk "$REPO/.venv/bin/cofo-desk" --device 24793885-E0D3-DAA3-9DD8-4271F4793A63)
mark() { printf '{"event":"case","case":"%s","time":"%s"}\n' "$1" "$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$LOG"; }
wait_enter() { read -r -p "   $1 " _ < /dev/tty; }
case_start() { echo; echo "== $1"; echo "   $2"; wait_enter "Press Enter to start."; mark "$1"; }

echo "Close the phone COFO app. Start with the desk at M2 (sitting)."
wait_enter "Press Enter to reinstall the agent with short countdowns."
LINES=$(wc -l < "$LOG" 2>/dev/null || echo 0)
"$REPO/timer-desk/install.sh" "${DESK[@]}" --sit-after 20 --stand-after 20 --snooze 20 || exit 1
echo "Waiting up to 30 s for the desk connection..."
for _ in $(seq 30); do
    tail -n +$((LINES + 1)) "$LOG" | grep -q desk-session-ready && break
    sleep 1
done
if ! tail -n +$((LINES + 1)) "$LOG" | grep -q desk-session-ready; then
    echo "The agent did not connect to the desk. Stopping here; recent log:"
    tail -n +$((LINES + 1)) "$LOG" | tail -5
    exit 1
fi
echo "Connected. The menu bar should show an up arrow counting down from 0:20."

case_start 1-cycle "Keep moving the mouse. Expect: at 0:00 a 1 cm jog, 3 s pause, rise to M1, then the menu bar shows a down arrow from 0:20; at 0:00 a jog, 3 s pause, back to M2."
wait_enter "Press Enter when the desk is back at M2."
case_start 2-cancel "Keep moving the mouse. When the jog happens, press any panel key within 3 s. Expect: no rise, and the menu bar counts down from 0:20 again."
wait_enter "Press Enter after the cancel."
case_start 3-waits-for-you "Do not touch the mouse or keyboard for 90 s (a timer runs below). Expect: the desk stays still and the menu bar shows waiting for you. Then move the mouse: the jog follows."
sleep 90
wait_enter "Now move the mouse, watch the desk rise, then press Enter."
case_start 4-by-hand "Press M2 on the panel. Expect: when the desk passes the middle, the menu bar switches to an up arrow from 0:20. The next move is a rise."
wait_enter "Press Enter after the switch."

mark end
mkdir -p "$DIR/out"
cp "$LOG" "$DIR/out/cycle-cases.log"
echo
echo "Reinstalling the daily setup (25 min sitting, 10 min standing, Clock timers on)."
"$REPO/timer-desk/install.sh" "${DESK[@]}" --clock
echo "Copied the log to $DIR/out/cycle-cases.log"
