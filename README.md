# Usage Dashboard

A macOS menu bar app that shows your ZCode (Z.ai) coding plan quota and your DeepSeek balance. The menu bar label shows remaining percentages at a glance. Click it to open a panel with the details.

## What it shows

- **Z.ai Coding Plan.** Plan level, 5-hour window, and weekly window with used and total requests, plus reset times.
- **DeepSeek.** USD balance from the DeepSeek API, plus token and request counts for today, the last 5 hours, and the week, read from the local ZCode database.
- The panel refreshes when you open it, when the app becomes active, and every 60 seconds.

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

A menu bar item appears with a label like `5h 100% · wk 42% · $1.65`. Click it to open the panel. The app has no dock icon and no main window. It lives in the menu bar.

## Wire it to your system

### Z.ai quota

`Sources/ZCodeQuotaService.swift` reads the access token from `~/.zcode/v2/credentials.json` (`oauth:zai:access_token`) and decrypts it with the scheme the ZCode CLI uses. That scheme takes the key from the `ZCODE_CREDENTIAL_SECRET` environment variable, or falls back to a key derived from your home path and username. The service then calls the undocumented endpoint `https://api.z.ai/api/monitor/usage/quota/limit`.

If ZCode stored your token while `ZCODE_CREDENTIAL_SECRET` was set, the app picks that variable up at runtime. No configuration is needed for a default ZCode install.

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

- The quota endpoint and the `enc:v1` credential format are undocumented. A ZCode update can break the quota row until someone updates the service.
- The local token counts are what ZCode recorded, not what DeepSeek reports.
- `build/panel.png`, which `check.sh` renders, contains your real usage numbers. Do not commit or share it.
