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
echo "→ Generating Pepper.xcodeproj…"
xcodegen generate

echo
echo "✅ Done. Open the project:"
echo "   open Pepper.xcodeproj"
echo
echo "Then in Xcode:"
echo "  1. Cmd-R to build & run. Signing is pinned to the Developer ID"
echo "     team in project.yml (so TCC grants survive rebuilds); without"
echo "     that cert, change DEVELOPMENT_TEAM / CODE_SIGN_IDENTITY locally"
echo "     and don't commit it."
echo "  2. Click the menu bar icon (record.circle) to start recording,"
echo "     or press the record shortcut (default ⌘⇧R; set in Settings)."
