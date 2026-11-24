#!/bin/bash
# Builds bin/TimerDesk.app and signs it with the local identity (scripts/create-signing-identity.sh),
# so privacy grants survive rebuilds. TIMER_DESK_SIGN picks another identity ("-" signs ad hoc).
# The new app replaces the old one only once it is complete, so a running one is not disturbed.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"
swift build -c release --package-path "$DIR"
NEW="$DIR/bin/new/TimerDesk.app"
rm -rf "$DIR/bin/new" "$DIR/bin/old"
mkdir -p "$NEW/Contents/MacOS"
cp "$DIR/.build/release/timer-desk" "$NEW/Contents/MacOS/timer-desk"
cp "$DIR/Info.plist" "$NEW/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :TimerDeskRepo string $REPO" "$NEW/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :TimerDeskCommit string $(git -C "$REPO" rev-parse --short HEAD)" "$NEW/Contents/Info.plist"
codesign --force --sign "${TIMER_DESK_SIGN:-cofo-desk-auto local signing}" --identifier dev.cofodesk.timer-desk "$NEW"
if [ -e "$DIR/bin/TimerDesk.app" ]; then
    mkdir -p "$DIR/bin/old"
    mv "$DIR/bin/TimerDesk.app" "$DIR/bin/old/"
fi
mv "$NEW" "$DIR/bin/TimerDesk.app"
rm -rf "$DIR/bin/new" "$DIR/bin/old"
# Claims timerdesk:// URLs now rather than once the app has been opened.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DIR/bin/TimerDesk.app"
