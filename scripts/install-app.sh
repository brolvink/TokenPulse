#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_dir="$HOME/Library/Application Support/TokenPulse/Updater"
app_path="$HOME/Applications/TokenPulse.app"
label="com.bramrolvink.TokenPulse.updater"
domain="gui/$(/usr/bin/id -u)"
agent_path="$HOME/Library/LaunchAgents/$label.plist"
origin="$(/usr/bin/git -C "$root_dir" remote get-url origin)"
if [[ -z "$origin" || "$origin" =~ ^https?://[^/]*@ ]]; then
    echo "Configure origin without embedding credentials in its URL." >&2
    exit 1
fi

/bin/mkdir -p "$state_dir" "$(dirname "$agent_path")"
if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
    /bin/launchctl bootout "$domain/$label"
fi
printf '%s\n' "$origin" > "$state_dir/origin"
/usr/bin/install -m 755 "$root_dir/scripts/update-app.sh" "$state_dir/update-app.sh"
/bin/bash "$state_dir/update-app.sh" "$state_dir" "$app_path" --quiet

agent_temp="$(/usr/bin/mktemp "$state_dir/agent.XXXXXXXX")"
trap '/bin/rm -f "$agent_temp"' EXIT
/usr/bin/plutil -create xml1 "$agent_temp"
/usr/bin/plutil -insert Label -string "$label" "$agent_temp"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$agent_temp"
args=(/bin/bash "$state_dir/update-app.sh" "$state_dir" "$app_path")
for index in "${!args[@]}"; do
    /usr/bin/plutil -insert "ProgramArguments.$index" -string "${args[$index]}" "$agent_temp"
done
/usr/bin/plutil -insert RunAtLoad -bool YES "$agent_temp"
/usr/bin/plutil -insert StartInterval -integer 300 "$agent_temp"
/usr/bin/plutil -insert StandardOutPath -string "$state_dir/updater.log" "$agent_temp"
/usr/bin/plutil -insert StandardErrorPath -string "$state_dir/updater.log" "$agent_temp"
/usr/bin/plutil -lint "$agent_temp"
/bin/mv "$agent_temp" "$agent_path"
/bin/launchctl enable "$domain/$label"
/bin/launchctl bootstrap "$domain" "$agent_path"
/usr/bin/open "$app_path"
printf 'Installed %s. Updates check origin/main every five minutes.\n' "$app_path"
