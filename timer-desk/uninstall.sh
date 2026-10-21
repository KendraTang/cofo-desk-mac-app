#!/bin/bash
# Stops timer-desk and removes its LaunchAgent. Keeps the log and the built binary.
set -u
LABEL=dev.cofodesk.timer-desk
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "Stopped $LABEL"
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
