#!/bin/bash
# install.sh — build bd-hdr-unclamp, install it, and load the login agent.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/bin/bd-hdr-unclamp"
PLIST="$HOME/Library/LaunchAgents/com.adam.bd-hdr-unclamp.plist"
STATE="$HOME/.local/state/bd-hdr-unclamp"
LABEL="com.adam.bd-hdr-unclamp"

echo "== checking toolchain =="
command -v swiftc >/dev/null || { echo "swiftc not found — install the Xcode command line tools"; exit 1; }

echo "== building =="
mkdir -p "$HOME/bin" "$STATE" "$(dirname "$PLIST")"
swiftc -O "$HERE/bd-hdr-unclamp.swift" -o "$BIN"
chmod +x "$BIN"

echo "== writing launch agent =="
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$BIN</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>LowPriorityIO</key><true/>
    <key>Nice</key><integer>10</integer>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>$STATE/launchd.log</string>
    <key>StandardErrorPath</key><string>$STATE/launchd.log</string>
</dict>
</plist>
PLISTEOF

echo "== loading agent =="
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2
launchctl print "gui/$(id -u)/$LABEL" | grep -E "^\s+(state|pid)" | head -2

echo
echo "installed. Logs: $STATE/bd-hdr-unclamp.log"
echo "Kill switch: $BIN --pause   (and --resume)"
echo "Reminder: set the monitor's own HDR mode for the peak brightness you want —"
echo "this tool only removes the software clamp."
