#!/bin/bash
# Builds a release timer-desk with its Info.plist embedded and signs it with the local identity
# (scripts/create-signing-identity.sh), so privacy grants survive rebuilds. Output: bin/timer-desk
# The new binary replaces the old one in a single rename, so a running agent is not disturbed.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
swift build -c release --package-path "$DIR" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIR/Info.plist"
mkdir -p "$DIR/bin"
cp "$DIR/.build/release/timer-desk" "$DIR/bin/timer-desk.new"
codesign --force --sign "cofo-desk-auto local signing" --identifier dev.cofodesk.timer-desk "$DIR/bin/timer-desk.new"
mv -f "$DIR/bin/timer-desk.new" "$DIR/bin/timer-desk"
