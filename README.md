# Usage Dashboard

A macOS menu bar app that shows your ZCode (Z.ai) coding plan quota, your ZCode Start Plan balance, and your DeepSeek balance. The menu bar label shows remaining percentages at a glance. Click it to open a panel with the details.

![Panel showing Z.ai quota, Start Plan balance, and DeepSeek balance](Resources/screenshot.png)

## What it shows

- **Z.ai Coding Plan.** Plan level, 5-hour window, and weekly window with used and total requests, plus reset times. Under each window, a per-model breakdown of the tokens it consumed (for example `GLM-5.3-Flash 1.3B · 76%`), aligned to the window's own time range. The split is token share only; the quota itself is plan-wide, so there is no per-model remaining.
- **Start Plan.** Plan name and one row per model pool (for example GLM-5.3-Flash and GLM-5.3) with used and total tokens and the expiry time, for one-time plans like the 1024 Dev Day.
- **DeepSeek.** USD balance from the DeepSeek API, plus token and request counts for today, the last 5 hours, and the week, read from the local ZCode database.
- The panel refreshes when you open it, when the app becomes active, and every 60 seconds. The menu bar label headlines the binding window, the one with the lowest remaining, as `5h 43% · start 96% · $1.65` (or `wk 0%` when the weekly window is the one blocking you), and gains a ⚠ when any window drops under 10% remaining.

## Requirements

- macOS 13 or later on Apple Silicon
- ZCode CLI installed, because it provides the credentials for the quota API and the local usage database
- A DeepSeek API key, for the balance row only

## Install

Clone this repo, then use the prebuilt app or build it yourself:

	sh ./build.sh

`build.sh` compiles the app with `swiftc`, signs it with an ad-hoc signature, and writes `UsageDashboard.app`. There is no Xcode project.

To check that everything works on your machine, run:

	sh ./check.sh

`check.sh` compiles and runs a self-test that fetches your real quota and balance and prints them as JSON, runs a probe that verifies the refresh-on-activation behavior, and renders a snapshot of the panel to `build/panel.png`.

## Run

	open UsageDashboard.app

A menu bar item appears with a label like `5h 43% · start 96% · $1.65`. Click it to open the panel. The app has no dock icon and no main window. It lives in the menu bar.

## Wire it to your system

### Z.ai quota

`Sources/ZCodeQuotaService.swift` reads the access token from `~/.zcode/v2/credentials.json` (`oauth:zai:access_token`) and decrypts it with the scheme the ZCode CLI uses. That scheme takes the key from the `ZCODE_CREDENTIAL_SECRET` environment variable, or falls back to a key derived from your home path and username. The service then calls the undocumented endpoints `https://api.z.ai/api/monitor/usage/quota/limit` for the windows and `https://api.z.ai/api/monitor/usage/model-usage` for the per-model token split, both found by reading the ZCode app bundle.

If ZCode stored your token while `ZCODE_CREDENTIAL_SECRET` was set, the app picks that variable up at runtime. No configuration is needed for a default ZCode install.

### Start Plan balance

`Sources/StartPlanService.swift` reads the `zcodejwttoken` credential with the same decryption scheme and calls the undocumented endpoint `https://zcode.z.ai/api/v1/zcode-plan/billing/balance`. The endpoint rejects requests that do not carry ZCode's own client headers (user agent, app version, device id), so the service sends the same set the desktop app sends. The `app_version` query parameter is pinned to the installed ZCode version.

### DeepSeek balance

Put your DeepSeek API key in the `DEEPSEEK_API_KEY` environment variable, or in a file at `~/.deepseek_key`:

	echo "sk-..." > ~/.deepseek_key
	chmod 600 ~/.deepseek_key

`Sources/DeepSeekService.swift` calls `https://api.deepseek.com/user/balance` with that key.

### Local token usage

`Sources/DeepSeekService.swift` also queries `~/.zcode/cli/db/db.sqlite` read-only through `/usr/bin/sqlite3`. This data stays on your machine.

### Add a provider

A provider is three pieces:

1. A service file in `Sources/` with a `static func fetch() async -> Loadable<T>` that returns a `Sendable` model. `Sources/DeepSeekService.swift` is the example to copy.
2. A model struct in `Sources/UsageModel.swift`.
3. A row in `Sources/DashboardView.swift`, plus a field on `Snapshot` and a property on `UsageStore` in the same file.

Or paste this prompt into ZCode and let it do the wiring:

	Look at Sources/DeepSeekService.swift, Sources/UsageModel.swift, and
	Sources/DashboardView.swift to learn the provider pattern. Add a
	new provider with these inputs:

	- Name: <PROVIDER NAME>
	- Data source: <API URL OR LOCAL FILE>
	- Auth: <ENV VAR OR KEY FILE, OR "none">
	- Display: <WHAT THE ROW SHOULD SHOW>

	Add a service file, a model struct, a Snapshot field, a UsageStore
	property, and a dashboard row for it. Then run ./check.sh and fix
	anything that fails.

### Remove a provider

Delete the provider's service file, its model struct, its `Snapshot` field, its `UsageStore` property, and its rows in `DashboardView.swift`. Then run `./check.sh` to confirm the app still builds. The add-provider prompt above works for removal too if you change the instruction to "Remove the <PROVIDER NAME> provider".

## Limits

- The quota endpoints and the `enc:v1` credential format are undocumented. A ZCode update can break the quota rows or the Start Plan balance (the app version and client headers are pinned) until someone updates the services.
- The local token counts are what ZCode recorded, not what DeepSeek reports.
- `build/panel.png`, which `check.sh` renders, contains your real usage numbers. Do not commit or share it. `Resources/screenshot.png` in this README also shows real numbers from when it was captured.
