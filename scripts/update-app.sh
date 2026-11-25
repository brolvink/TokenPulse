#!/bin/bash
set -euo pipefail

# launchd does not inherit the interactive shell's PATH.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"
export GIT_TERMINAL_PROMPT=0

state_dir="${1:?Missing updater state directory}"
app_path="${2:?Missing app path}"
quiet="${3:-}"
repository="$state_dir/repository.git"
app_executable="$app_path/Contents/MacOS/TokenPulse"
plist_tool=/usr/libexec/PlistBuddy

running_pids() {
    /bin/ps -axo pid=,command= | /usr/bin/awk -v executable="$app_executable" '
        {
            pid = $1
            sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
            if ($0 == executable) print pid
        }
    '
}

if [[ ! -f "$state_dir/origin" ]]; then
    echo "TokenPulse updater has no origin configured." >&2
    exit 1
fi
origin="$(<"$state_dir/origin")"
set --
if [[ "$origin" == https://github.com/* ]] && gh_path="$(command -v gh)"; then
    # Keep the fallback scoped to this repository fetch, without changing Git config.
    printf -v gh_helper '!%q auth git-credential' "$gh_path"
    set -- -c "credential.https://github.com.helper=$gh_helper"
fi

# launchd coalesces scheduled runs. This lock also guards manual runs.
lock="$state_dir/update.lock"
if ! /bin/mkdir "$lock" 2>/dev/null; then
    locked_pid="$(/bin/cat "$lock/pid" 2>/dev/null || true)"
    if [[ ! "$locked_pid" =~ ^[0-9]+$ ]] || kill -0 "$locked_pid" 2>/dev/null; then
        exit 0
    fi
    /bin/rm -f "$lock/pid"
    /bin/rmdir "$lock" 2>/dev/null || exit 0
    /bin/mkdir "$lock" 2>/dev/null || exit 0
fi
printf '%s\n' "$$" > "$lock/pid"

build_dir=
stage_dir=
previous_pids=
cleanup() {
    if [[ -n "$build_dir" ]]; then /bin/rm -rf "$build_dir"; fi
    if [[ -n "$stage_dir" ]]; then
        if [[ -e "$stage_dir/Previous.app" && ! -e "$app_path" ]]; then
            if /bin/mv "$stage_dir/Previous.app" "$app_path"; then
                if [[ -n "$previous_pids" ]]; then /usr/bin/open -n "$app_path" || true; fi
            else
                echo "The previous build is at $stage_dir/Previous.app" >&2
            fi
        fi
        if [[ -e "$app_path" || ! -e "$stage_dir/Previous.app" ]]; then
            /bin/rm -rf "$stage_dir"
        fi
    fi
    /bin/rm -f "$lock/pid"
    /bin/rmdir "$lock"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! -d "$repository" ]]; then
    /usr/bin/git init --quiet --bare "$repository"
fi
/usr/bin/git "$@" --git-dir="$repository" fetch --quiet --depth=1 --no-tags -- "$origin" refs/heads/main
revision="$(/usr/bin/git --git-dir="$repository" rev-parse --verify 'FETCH_HEAD^{commit}')"
installed="$("$plist_tool" -c 'Print :TokenPulseGitRevision' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$revision" == "$installed" && -x "$app_executable" ]]; then
    exit 0
fi

build_dir="$(/usr/bin/mktemp -d "$state_dir/build.XXXXXXXX")"
/usr/bin/git --git-dir="$repository" archive "$revision" | /usr/bin/tar -xf - -C "$build_dir"
/bin/bash "$build_dir/scripts/build-app.sh"

build_app="$build_dir/dist/TokenPulse.app"
build_plist="$build_app/Contents/Info.plist"
if [[ "$("$plist_tool" -c 'Print :CFBundleIdentifier' "$build_plist")" != "com.bramrolvink.TokenPulse" ||
      ! -x "$build_app/Contents/MacOS/TokenPulse" ]]; then
    echo "The build did not produce a valid TokenPulse app." >&2
    exit 1
fi
"$plist_tool" -c "Add :TokenPulseGitRevision string $revision" "$build_plist"
/usr/bin/codesign --force --sign - "$build_app"
/usr/bin/codesign --verify --deep --strict "$build_app"

# Stage on the app's filesystem before touching the installed bundle.
/bin/mkdir -p "$(dirname "$app_path")"
stage_dir="$(/usr/bin/mktemp -d "$(dirname "$app_path")/.tokenpulse-update.XXXXXXXX")"
/usr/bin/ditto "$build_app" "$stage_dir/TokenPulse.app"
/usr/bin/codesign --verify --deep --strict "$stage_dir/TokenPulse.app"

previous_pids="$(running_pids)"
if [[ -n "$previous_pids" ]]; then
    while IFS= read -r pid; do
        kill -TERM "$pid" 2>/dev/null || true
    done <<< "$previous_pids"
    for ((attempt = 0; attempt < 20; attempt++)); do
        [[ -n "$(running_pids)" ]] || break
        /bin/sleep 0.25
    done
    if [[ -n "$(running_pids)" ]]; then
        echo "TokenPulse is still running. The update will be retried." >&2
        exit 1
    fi
fi

rollback() {
    if [[ -e "$stage_dir/Previous.app" ]]; then
        /bin/mv "$stage_dir/Previous.app" "$app_path"
        if [[ -n "$previous_pids" ]]; then /usr/bin/open -n "$app_path" || true; fi
    fi
}

if [[ -e "$app_path" ]]; then
    /bin/mv "$app_path" "$stage_dir/Previous.app"
fi
if ! /bin/mv "$stage_dir/TokenPulse.app" "$app_path"; then
    rollback
    exit 1
fi
if [[ -n "$previous_pids" ]] && ! /usr/bin/open -n "$app_path"; then
    /bin/mv "$app_path" "$stage_dir/Failed.app"
    rollback
    exit 1
fi

# A successful install also refreshes the persistent runner for the next poll.
latest_runner="$build_dir/scripts/update-app.sh"
if [[ -f "$latest_runner" ]]; then
    runner_temp="$(/usr/bin/mktemp "$state_dir/runner.XXXXXXXX")"
    if /usr/bin/install -m 755 "$latest_runner" "$runner_temp"; then
        /bin/mv -f "$runner_temp" "$state_dir/update-app.sh"
    else
        /bin/rm -f "$runner_temp"
    fi
fi

printf 'Installed TokenPulse %s\n' "$revision"
if [[ "$quiet" != "--quiet" ]]; then
    /usr/bin/osascript -e 'display notification "The latest version from main is installed." with title "TokenPulse updated"' || true
fi
