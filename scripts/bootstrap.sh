#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_BIN="$REPO_ROOT/.local/bin"
mkdir -p "$LOCAL_BIN"
export PATH="$LOCAL_BIN:$PATH"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "→ xcodegen not found. Building from source (one-time, ~1 min)…"
    BUILD_DIR="$REPO_ROOT/.local/src/XcodeGen"
    if [ ! -d "$BUILD_DIR/.git" ]; then
        rm -rf "$BUILD_DIR"
        git clone --depth 1 https://github.com/yonaskolb/XcodeGen.git "$BUILD_DIR"
    fi
    (
        cd "$BUILD_DIR"
        swift build -c release --disable-sandbox
        cp -f ".build/release/xcodegen" "$LOCAL_BIN/xcodegen"
    )
    echo "→ xcodegen installed at $LOCAL_BIN/xcodegen"
fi

cd "$REPO_ROOT"
echo "→ Generating Mentor.xcodeproj…"
xcodegen generate

echo
echo "✅ Done. Open the project:"
echo "   open Mentor.xcodeproj"
echo
echo "Then in Xcode:"
echo "  1. Select the Mentor target → Signing & Capabilities"
echo "  2. Set your Team (your Apple ID is fine for local dev)"
echo "  3. Cmd-R to build & run"
echo "  4. Click the menu bar icon (record.circle) to start recording"
echo "     Or press ⌘⇧R from anywhere to toggle"
