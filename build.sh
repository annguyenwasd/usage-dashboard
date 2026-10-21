#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

rm -rf UsageDashboard.app
mkdir -p UsageDashboard.app/Contents/MacOS

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
	Sources/UsageModel.swift \
	Sources/ZCodeQuotaService.swift \
	Sources/DeepSeekService.swift \
	Sources/DashboardView.swift \
	Sources/AppMain.swift \
	-o UsageDashboard.app/Contents/MacOS/UsageDashboard

cp Resources/Info.plist UsageDashboard.app/Contents/Info.plist
codesign --force --sign - UsageDashboard.app

echo "Built UsageDashboard.app"
