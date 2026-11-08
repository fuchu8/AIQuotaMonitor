# AI Quota Monitor

[中文](https://github.com/fuchu8/AIQuotaMonitor) · **English**

A macOS menu-bar app that shows quotas for **OpenAI Codex**, **Cursor**, **OpenCode Go**, and **Grok Bot**. Native Swift / SwiftUI / AppKit, no third-party dependencies. It stays in the menu bar and does not take a Dock icon.

Bundle ID: `com.skye.aiquotamonitor` · version **1.4.6** · macOS 14+.

This repository is the program only. It does not contain the author's API keys, access tokens, accounts, or private endpoints. Each person uses the Codex, Cursor, OpenCode Go, or Grok Bot login already on their own Mac.

---

## Use it after you download

You need macOS 14 or later, plus Xcode or the Command Line Tools (they provide `swift`).

```bash
git clone https://github.com/fuchu8/AIQuotaMonitor.git
cd AIQuotaMonitor
./build.sh
cp -R -P -p -X "dist/AI Quota Monitor.app" /Applications/
open "/Applications/AI Quota Monitor.app"
```

The app does not appear in the Dock. After it opens, look at the right side of the menu bar for a round cat icon. Hover for a short quota summary. Click to open the detail panel. Refresh and Settings are at the top right. Quit is in the menu at the bottom.

Each service uses your own login. Do not put keys into this project:

| Quota | What you set up first |
|---|---|
| Codex | `codex` is installed and signed in on this Mac. The app calls its `app-server` account read APIs only. |
| Cursor | The Cursor desktop app stays signed in. The app reads the existing login from the local keychain. |
| Grok Bot | Same login as Cursor / Grok Bot. The weekly pool is shared with Grok and Cursor. It is not a separate extra quota. |
| OpenCode Go percentages | OpenCode is signed in, or your own `oc_` key is in the local environment variable `OPENCODE_GO_API_KEY` or `OPENCODE_API_KEY`. Keep the key on your machine. Do not commit it. |
| OpenCode Go token columns | These count matching usage in local `~/.workbuddy/logs` only. On another Mac, or when logs are incomplete, the three columns are incomplete. Percentages still come from the official API. |

If Cursor's official percentage cannot be read, import a CSV exported from the [Cursor Dashboard](https://cursor.com/dashboard?tab=usage), or type a used percentage by hand. That path is a fallback.

Settings cover the refresh interval (1 / 5 / 15 / 30 minutes), low-quota alerts, launch at login, and showing or hiding the desktop card. Drag the desktop card from the bars labeled for dragging at the top or bottom. It is a normal window, not a system Widget you add from System Settings.

---

## 1. Data sources

| Platform | Source | Status | Fields |
|---|---|---|---|
| Codex | Official app server `account/rateLimits/read` | Available | Pools, used percent, reset time, credits, rate-limit state |
| Codex | Official `account/read` / `account/usage/read` | Available | Account and plan, daily and lifetime tokens |
| Cursor | Local login → DashboardService (not a stable public API) | Available | Used percent for Cursor Models and Other Models; tokens for today, this period, and about 90 days |
| Cursor | Official Dashboard CSV export, or manual entry | Fallback | CSV token detail; a typed percentage |
| Cursor | Local `state.vscdb` / `ai-code-tracking.db` | Metadata | Plan, subscription state, version, local snippet call counts (not the quota) |
| OpenCode Go | Official `/zen/go/v1/usage` | Available | Used percent for 5 hours, weekly, and monthly |
| OpenCode Go | Incremental total from local ModelProvider logs | Available | Tokens for today, this period or about 30 days, and the range the logs cover. This is not a WorkBuddy credit balance. |
| Grok Bot | Local login → `GetSandUsageStatus` | Available | Weekly pool used percent |

This version does not monitor WorkBuddy credits and does not read `workbuddy.db`. If Go token logs are still under `~/.workbuddy/logs`, the UI labels them as local Go logs and does not treat them as a WorkBuddy balance.

---

## 2. Features

**Menu bar**
- The cat icon stays as an icon. Hover shows a tooltip. Click opens an `NSPopover`. The item does not expand on hover and does not change width.
- The tooltip can show remaining or used, and which Codex window to represent.

**Desktop card**
- A draggable window at normal level. It is not a system widget. Show or hide it from Settings or the detail panel. The position is remembered. See `WIDGET.md`.

**Panel**
- Four cards: Codex, Cursor, OpenCode Go, and Grok Bot. The middle scrolls, and the height follows the screen.
- Quota and token rows record their own success times. A failed fetch keeps the previous value and marks it stale.
- Go token rows state the covered range and that the figure is a model-matched estimate.

**Settings**
- Refresh every 1, 5, 15, or 30 minutes. The next timer uses the new value immediately.
- Alerts at 20% or below, 10% or below, and on reset. Turning off the reset notice does not block the next period's low-quota alert.
- Launch at login, Cursor CSV import, and manual entry.

---

## 3. Build

```bash
cd AIQuotaMonitor
./build.sh              # release + ad-hoc signature → dist/AI Quota Monitor.app
swift test              # WAL read-only, Codex dedupe, alert periods, Go merge and incremental logs
```

Install:

```bash
cp -R -P -p -X "dist/AI Quota Monitor.app" /Applications/
open "/Applications/AI Quota Monitor.app"
```

---

## 4. Diagnostics

```bash
B="/Applications/AI Quota Monitor.app/Contents/MacOS/AIQuotaMonitor"
"$B" --diagnose          # per-source status; non-zero on failure or timeout; redacted by default
"$B" --render-panel      # wait for refresh, then render offscreen to /tmp/aqm/panel.png
```

Log: `~/Library/Application Support/AIQuotaMonitor/app.log` (no credentials)  
History: `~/Library/Application Support/AIQuotaMonitor/history.sqlite3`

---

## 5. Privacy

- No separate telemetry service.
- Authenticated usage queries go only to the matching vendor: Codex app server, Cursor and Grok account APIs, and OpenCode Go.
- The app does not copy `~/.codex/auth.json` into logs, and it does not write Cursor tokens or OpenCode Go keys into its settings, history, or logs.
- It may read the Cursor login already in the local keychain, and token lines in local Go logs.
- It does not change Codex, Cursor, WorkBuddy, or OpenCode login state, settings, or project files. It does not uninstall WorkBuddy or delete its data.

---

## 6. Layout

```
Sources/AIQuotaMonitor/          # AIQuotaMonitorCore
Sources/App/main.swift           # executable entry
Tests/AIQuotaMonitorTests/       # regression tests
```
