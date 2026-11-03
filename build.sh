#!/bin/bash
#
# Builds MaaPlugin.dylib for Mac Catalyst through the Xcode project, so the
# project file stays the single source of truth for sources and build settings.
#
#   ./build.sh            # Release (default)
#   ./build.sh Debug      # Debug
#
# Product: build/MaaPlugin.dylib (copied from Xcode's output directory).
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
CONFIG="${1:-Release}"

xcodebuild \
    -project "$ROOT/MaaPlugin.xcodeproj" \
    -scheme MaaPlugin \
    -configuration "$CONFIG" \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$ROOT/build/xcode" \
    build

PRODUCT="$ROOT/build/xcode/Build/Products/$CONFIG-maccatalyst/MaaPlugin.dylib"
if [ ! -f "$PRODUCT" ]; then
    echo "error: expected product not found: $PRODUCT" >&2
    exit 1
fi

mkdir -p "$ROOT/build"
cp "$PRODUCT" "$ROOT/build/MaaPlugin.dylib"

echo
lipo -info "$ROOT/build/MaaPlugin.dylib"
vtool -show-build "$ROOT/build/MaaPlugin.dylib" | grep -m1 -A2 "platform"
echo
echo "Built: $ROOT/build/MaaPlugin.dylib"
