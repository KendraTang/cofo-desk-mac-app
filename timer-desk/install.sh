#!/bin/bash
# Builds TimerDesk.app and starts it, replacing a running one. Arguments go to this run only and are
# not saved (see timer-desk --help). Also removes the LaunchAgent that older versions installed.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL=dev.cofodesk.timer-desk
APP="$DIR/bin/TimerDesk.app"

"$DIR/build.sh"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$DIR/bin/timer-desk"
pkill -x timer-desk 2>/dev/null || true
while pgrep -x timer-desk >/dev/null; do sleep 0.2; done
if [ $# -gt 0 ]; then
    open "$APP" --args "$@"
else
    open "$APP"
fi
echo "Started $APP; logging to $HOME/Library/Logs/timer-desk.log"
