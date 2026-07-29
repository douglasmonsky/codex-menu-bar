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
