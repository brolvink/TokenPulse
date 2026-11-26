# TokenPulse

A macOS menu bar app for tracking **Claude**, **Codex**, and **Gemini Antigravity** subscription quotas and spotting unused quota before it resets.

## Features

- The inner ring shows short-term quota and the outer ring shows weekly quota. Claude is at the top, Codex at the lower right, and Antigravity at the lower left. A dot in the center marks the provider with the highest-priority opportunity to use quota. Click for the values and reset times.
- **Multi-Window Quota Tracking**:
  - **Claude**: Reads OAuth credentials from macOS Keychain (`Claude Code-credentials`) or `~/.claude/.credentials.json` to query `api.anthropic.com/api/oauth/usage` (5-hour session, 7-day weekly, Opus/Sonnet breakdown), plus local `~/.claude/projects` JSONL token stats.
  - **Codex**: Reads `~/.codex/auth.json` to query `chatgpt.com/backend-api/wham/usage`, with automatic fallback to `~/.codex/sessions/**/*.jsonl` `rate_limits` and token usage rollouts.
  - **Gemini Antigravity**: Prefers the [CLI status-line quota feed](https://antigravity.google/docs/cli/statusline/). Falls back to the Cloud Code Assist quota request.
- **Freshness**. Each provider shows when its quota was last read. The last successful readings are saved locally and restored on launch or after a failed refresh. Cached values are marked until the quota window resets.
- **Weekly forecast**. After at least a day of live readings in the same cycle, the footer can estimate how much weekly quota will go unused at reset. Reading history stays on your Mac.
- **Surplus alerts**. TokenPulse can notify you when unused quota is approaching a reset or another provider is running low.
- **Demo Mode**: Toggle sample data in Settings to preview alerts and UI at any time.

## Install

On macOS 14 or later, install the Xcode Command Line Tools. Then run these commands:

```bash
git clone https://github.com/brolvink/TokenPulse.git
cd TokenPulse
./scripts/install-app.sh
```

The installer builds `origin/main`, installs TokenPulse in `~/Applications`, and registers a per-user updater.

## Automatic updates

Push to `origin/main` to publish an update. While you’re logged in, the updater checks for changes every five minutes. When it sees a new commit, it builds and verifies the app locally before replacing the installed copy. It relaunches TokenPulse if it was running and posts a macOS notification when the update is installed.

To check now:

```bash
launchctl kickstart gui/$(id -u)/com.bramrolvink.TokenPulse.updater
```

Update logs are in `~/Library/Application Support/TokenPulse/Updater`. To disable automatic updates while keeping the app, run `./scripts/uninstall-updater.sh`.

## Development

```bash
./scripts/build-app.sh
open dist/TokenPulse.app
```

This build runs directly from the checkout. Use the installer above for automatic updates.

Or run directly during development:

```bash
swift run
```

Run tests:

```bash
./scripts/test.sh
```

## Connect the Antigravity CLI

Add a `statusLine` command to the Antigravity CLI settings. Point it to the built app executable with the capture flag, and set `stack_with_default` to `true` to keep the CLI’s built-in status line.

```text
~/Applications/TokenPulse.app/Contents/MacOS/TokenPulse --capture-antigravity-quota
```

Quote the executable path if it contains spaces. Open a new `agy` session to start receiving updates. TokenPulse stores quota fractions and reset times in its local cache.

## License

[MIT License](LICENSE)
