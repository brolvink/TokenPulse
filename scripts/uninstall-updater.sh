#!/bin/bash
set -euo pipefail

label="com.bramrolvink.TokenPulse.updater"
domain="gui/$(/usr/bin/id -u)"
if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
    /bin/launchctl bootout "$domain/$label"
fi
/bin/rm -f "$HOME/Library/LaunchAgents/$label.plist"
echo "TokenPulse automatic updates are disabled. The installed app is still available."
