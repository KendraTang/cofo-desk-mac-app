#!/bin/bash
# Stops timer-desk and removes it from the login items. Keeps the log, the settings and the built app.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL=dev.cofodesk.timer-desk
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
[ -x "$DIR/bin/TimerDesk.app/Contents/MacOS/timer-desk" ] && "$DIR/bin/TimerDesk.app/Contents/MacOS/timer-desk" --unregister-login-item
pkill -x timer-desk && echo "Stopped timer-desk"
