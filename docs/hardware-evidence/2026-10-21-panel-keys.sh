#!/bin/bash
# Read-only: the script never sends motion. You press the desk panel keys while it records.
# Checks (1) whether opcodes 25-28 are the M1-M3 heights and (2) whether manual key presses
# produce live height notifications.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO=/Users/tkain/projects/cofo-desk-auto
DEVICE='24793885-E0D3-DAA3-9DD8-4271F4793A63'
LOG="$DIR/2026-10-21-panel-keys.log"

: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "===== start $(date '+%H:%M:%S')"
echo "Recording 60 s. On the panel: press M1, wait until it stops; press M2, wait until it stops;"
echo "then hold UP about 1 s. Type the panel height after each stop into the notes below."
"$REPO/.venv/bin/cofo-desk" --json --trace --device "$DEVICE" watch --seconds 60
echo "rc=$?"
read -r -p "Panel height after M1? " a < /dev/tty; echo "ANSWER[M1] $a"
read -r -p "Panel height after M2? " b < /dev/tty; echo "ANSWER[M2] $b"
echo "===== end $(date '+%H:%M:%S')"
