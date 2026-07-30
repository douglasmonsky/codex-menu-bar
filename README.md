# Codex Menu Bar

Codex Menu Bar is an unofficial macOS utility that displays remaining Codex
ChatGPT rate-limit percentages in the system menu bar. It communicates with a
locally managed Codex App Server over stdio and does not read or store
conversation content.

## MVP status

The app targets macOS 14 or newer and uses the versioned App Server protocol
provided by the installed Codex CLI. It shows the `codex` bucket, supports
manual and periodic refresh, and keeps the last successful values during a
transient disconnect.

Build from the command line:

```bash
xcodebuild \
  -project CodexMenuBar.xcodeproj \
  -scheme CodexMenuBar \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run tests with the `CodexMenuBarTests` scheme using the same destination and
`CODE_SIGNING_ALLOWED=NO` setting.

The app is intentionally small: it does not send prompts, inspect sessions,
store history, open a listener, or install/update Codex.

## iPhone widget without an Apple Developer account

The Mac app can export its aggregate usage snapshot to the Scriptable iCloud
container. It writes only percentages, window durations, reset timestamps, and
the last-updated time. It does not export credentials or conversation data.

Setup:

1. Install Scriptable from the App Store on the iPhone.
2. In Scriptable settings, enable iCloud.
3. Enable iCloud Drive for Scriptable on the Mac and iPhone.
4. Launch or refresh Codex Menu Bar on the Mac.
5. In the iPhone Home Screen widget picker, add Scriptable.
6. Edit the widget and choose the `Codex Usage` script.

The Mac app copies `Codex Usage.js` and `codex-usage.json` into Scriptable's
iCloud documents folder when that container becomes available. Widget refresh
timing is ultimately controlled by iOS.
