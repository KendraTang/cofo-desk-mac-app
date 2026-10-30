#!/bin/bash
# Builds timer-desk and (re)loads it as a LaunchAgent that starts at login and restarts if it exits.
# Arguments are passed to the agent, e.g. ./install.sh --length 10 --length 1500
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL=dev.cofodesk.timer-desk
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/timer-desk.log"

"$DIR/build.sh"

ARGS=""
for arg in "$DIR/bin/timer-desk" "$@"; do
    escaped=$(printf '%s' "$arg" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
    ARGS="$ARGS        <string>$escaped</string>
"
done

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
$ARGS    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout returns before the old process has gone, and bootstrap fails until it has.
for _ in 1 2 3 4 5 6 7 8 9; do
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && break
    sleep 1
done
launchctl print "gui/$(id -u)/$LABEL" >/dev/null || launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Loaded $LABEL; logging to $LOG"
