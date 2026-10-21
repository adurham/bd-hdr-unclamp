#!/bin/bash
# install.sh — build bd-hdr-unclamp, install it, and load the login agent.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/bin/bd-hdr-unclamp"
PLIST="$HOME/Library/LaunchAgents/com.adam.bd-hdr-unclamp.plist"
STATE="$HOME/.local/state/bd-hdr-unclamp"
CONFIG="$HOME/.config/bd-hdr-unclamp"
LABEL="com.adam.bd-hdr-unclamp"
BD="/opt/homebrew/bin/betterdisplaycli"

echo "== checking prerequisites =="
command -v swiftc >/dev/null || { echo "swiftc not found — install the Xcode command line tools"; exit 1; }
[ -x "$BD" ] || { echo "betterdisplaycli not found at $BD — install BetterDisplay first"; exit 1; }

echo "== building (to a temp path) =="
mkdir -p "$HOME/bin" "$STATE" "$CONFIG" "$(dirname "$PLIST")"
TMP="$(mktemp -d)/bd-hdr-unclamp"
swiftc -O "$HERE/bd-hdr-unclamp.swift" -o "$TMP"
codesign --force --sign - "$TMP" 2>/dev/null || true

echo "== stopping any running copy =="
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 1

echo "== installing binary =="
# replace atomically: overwriting a running signed binary in place makes macOS SIGKILL
# later execs of that same path (observed here as "Killed: 9")
rm -f "$BIN"
cp "$TMP" "$BIN"
chmod +x "$BIN"
codesign --force --sign - "$BIN" 2>/dev/null || true

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
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2
launchctl print "gui/$(id -u)/$LABEL" | grep -E "^\s+(state|pid)" | head -2

echo
echo "installed. Log: $STATE/bd-hdr-unclamp.log"
echo "kill switch: $BIN --pause   (resume with --resume)"
echo "ignore list: $CONFIG/ignore  (one app name per line)"
echo
echo "REQUIRED: in BetterDisplay keep 'Reset colors on neutral settings for HDR capable"
echo "screens' ENABLED (Settings > Displays > Overview). With it off, neutral controls may"
echo "leave the colour table installed and HDR still clipped."
echo
echo "Reminder: pick the monitor's own HDR mode for the peak brightness you want — this"
echo "tool only removes the software clamp."
