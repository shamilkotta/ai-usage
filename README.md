# AI Usage

A macOS Notification Center widget that shows how much of your AI subscription limits you've used — Claude, Codex, Cursor and Grok Bot — in one place, so you don't have to open each app or dashboard to check.

| Service | What's shown | Credentials used |
|---|---|---|
| **Claude** (Claude Code / claude.ai plan) | 5-hour and weekly limits (plus Opus/Sonnet weekly when your plan has them) | Claude Code login in the Keychain (`Claude Code-credentials`) |
| **Codex** (ChatGPT plan) | Plan rate-limit windows (e.g. 5h / weekly / monthly) | `~/.codex/auth.json` from `codex login` |
| **Cursor** | Auto and API (third-party model) usage for the billing cycle | Cursor's local login (`state.vscdb`) |
| **Grok Bot** | Weekly usage | Same Cursor account login |

Each bar shows the percentage used, color-coded (green → orange at 70% → red at 90%), and the time until it resets. The widget follows the system Light/Dark appearance (pure black in Dark Mode).

## How it works

The project has two parts:

- **AI Usage.app**: a background app with no Dock or menu bar icon. It starts at login, and every 3 minutes it reads your existing local logins and asks each service for your current usage. It writes the result to `~/.ai-usage-widget/usage.json`.
- **AI Usage widget**: a WidgetKit extension (medium and large sizes) that reads that file and renders it.

The split is necessary because macOS sandboxes widgets, so a widget can't read other apps' credentials or your Keychain.

### Privacy

- No accounts, API keys or configuration needed.
- Tokens are read locally and sent only to the service they belong to (`api.anthropic.com`, `chatgpt.com`, `cursor.com` / `api2.cursor.sh`).
- Nothing is stored except the usage percentages and reset times in `~/.ai-usage-widget/usage.json`.

### Caveat

None of these services offers a public usage API. The app calls the same internal endpoints their own apps and dashboards use, so any of them can change without notice. If a service shows *"Auth expired – open the app"*, open that tool (Claude Code, Codex, Cursor) once to refresh its login.

## Requirements

- macOS 14 or later
- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Logged in to whichever of Claude Code, Codex CLI and Cursor you use. Services you're not logged in to show a short message instead of usage.

## Build and install

```sh
xcodegen generate
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release -derivedDataPath build build
pkill -x "AI Usage"; rm -rf "/Applications/AI Usage.app"
ditto "build/Build/Products/Release/AI Usage.app" "/Applications/AI Usage.app" && open "/Applications/AI Usage.app"
```

The app is ad-hoc signed ("Sign to Run Locally"), so no Apple Developer account is needed. The first run may ask for Keychain access to read the Claude Code credentials. Choose **Always Allow**.

### Add the widget

Click the date and time in the menu bar → **Edit Widgets** → search **AI Usage** → choose Medium or Large.

If the widget still shows an old layout after a reinstall, remove it and add it again, or restart the widget host:

```sh
killall chronod NotificationCenter
```

## Usage

- **Refresh now:** open **AI Usage** from Applications or Spotlight. Nothing appears on screen, but it fetches immediately.
- **Stop it:** `pkill -x "AI Usage"`.
- **Disable at login:** turn it off under System Settings → General → Login Items.

macOS rations how often widgets redraw, so the widget can lag a few minutes behind the 3-minute fetch.

## Uninstall

```sh
pkill -x "AI Usage"
rm -rf "/Applications/AI Usage.app" ~/.ai-usage-widget
```

## Project layout

```
App/        background fetcher app (AppKit, no UI)
  Fetchers.swift   per-service usage fetchers
Widget/     WidgetKit extension (SwiftUI)
Shared/     usage model and JSON store shared by both targets
project.yml XcodeGen spec
```

### Adding a service

Write an `async throws -> ProviderUsage` function in `App/Fetchers.swift` that returns one or more `UsageWindow`s (label, percent used, reset date), then add it to `fetchAll()`.
