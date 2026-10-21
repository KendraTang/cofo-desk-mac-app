#!/bin/bash
# Spike B: snapshots the Accessibility tree while a Clock timer runs, with and without the Clock
# window, so the diff shows where (and whether) the countdown is readable.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
snap() { swift "$DIR/ax-dump.swift" "$1" || exit $?; }
pause() { read -r -p "$1 Press Enter when done. " _ < /dev/tty; }

snap 0-idle
pause "In Clock, start a 3-minute timer and leave the Clock window open."
snap 1-window-a; sleep 3; snap 1-window-b
pause "Close the Clock window (Cmd-W) but keep the timer running. Where do you still see the countdown? Note it."
snap 2-closed-a; sleep 3; snap 2-closed-b
pause "Pause the timer (from wherever you can)."
snap 3-paused
pause "Cancel the timer."
snap 4-cancelled
echo "Done. Output is in $DIR/out/"
