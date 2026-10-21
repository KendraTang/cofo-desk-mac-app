#!/bin/bash
# Spike B cases: records the timer menu extra while you run short Clock timers.
# Output: probes/out/ax-timer-cases.log
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR/out"
LOG="$DIR/out/ax-timer-cases.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "===== $(date '+%H:%M:%S') recording 150 s. Do these in Clock, about 5 s apart:"
echo "  1. 10 s timer, let it finish; dismiss the alert"
echo "  2. 10 s timer, pause at about 5 s, wait 10 s, resume, let it finish; dismiss"
echo "  3. 10 s timer, cancel at about 5 s"
echo "  4. 10 s timer, let it finish, and immediately start another 10 s timer; let both finish"
swift "$DIR/ax-timer-watch.swift" 150
echo "rc=$?"
