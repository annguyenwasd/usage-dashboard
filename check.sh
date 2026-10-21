#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
	Sources/UsageModel.swift \
	Sources/ZCodeQuotaService.swift \
	Sources/DeepSeekService.swift \
	Tools/SelfTest.swift \
	-o build/SelfTest

./build/SelfTest

swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
	Sources/UsageModel.swift \
	Sources/ZCodeQuotaService.swift \
	Sources/DeepSeekService.swift \
	Sources/DashboardView.swift \
	Tools/RenderPanel.swift \
	-o build/RenderPanel

./build/RenderPanel build/panel.png
