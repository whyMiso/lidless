#!/usr/bin/env bash
# Regenerate the Xcode project and build a Debug Lidless.app (Developer ID signed) into build/.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! grep -qE '^DEVELOPMENT_TEAM *= *[A-Z0-9]{10}' Config/Local.xcconfig 2>/dev/null; then
    echo "error: set your Team ID in Config/Local.xcconfig first:"
    echo "  cp Config/Local.xcconfig.example Config/Local.xcconfig   # then edit it"
    exit 1
fi
if command -v xcodegen >/dev/null 2>&1; then xcodegen generate >/dev/null; fi
xcodebuild -project Lidless.xcodeproj -scheme Lidless -configuration Debug \
    -derivedDataPath build/DerivedData build -quiet
echo "Built: build/DerivedData/Build/Products/Debug/Lidless.app"
