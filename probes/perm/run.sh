#!/bin/bash
# Builds and signs perm-probe, then runs it once as a LaunchAgent (not from this terminal, so it
# cannot borrow the terminal's grants). Run it again after granting the permissions macOS asks for.
# Output: probes/out/perm-probe.log
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
OUT="$REPO/probes/out"
BIN="$OUT/perm-probe"
LOG="$OUT/perm-probe.log"
LABEL=dev.cofodesk.perm-probe
PLIST="$OUT/$LABEL.plist"
DEVICE='24793885-E0D3-DAA3-9DD8-4271F4793A63'
IDENTITY="cofo-desk-auto local signing"

mkdir -p "$OUT"
swiftc -O "$DIR/main.swift" -o "$BIN" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIR/Info.plist" || exit 1
codesign --force --sign "$IDENTITY" --identifier "$LABEL" "$BIN" || exit 1
codesign -dr - "$BIN" 2>&1 | grep designated

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string><string>$LOG</string>
        <string>$REPO/.venv/bin/cofo-desk</string><string>$DEVICE</string>
    </array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF

rm -f "$LOG"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST" || exit 1
for _ in $(seq 60); do grep -q ' done$' "$LOG" 2>/dev/null && break; sleep 1; done
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
cat "$LOG" 2>/dev/null || echo "no log written"
