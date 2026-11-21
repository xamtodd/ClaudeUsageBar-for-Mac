#!/bin/bash
# Baut ClaudeUsageBar.app und installiert sie nach ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeUsageBar.app"
swift build -c release

rm -rf "build/$APP"
mkdir -p "build/$APP/Contents/MacOS"
cp .build/release/ClaudeUsageBar "build/$APP/Contents/MacOS/"
cp Info.plist "build/$APP/Contents/"
codesign --force --sign - "build/$APP"

mkdir -p ~/Applications
pkill -x ClaudeUsageBar 2>/dev/null || true
rm -rf ~/Applications/"$APP"
cp -R "build/$APP" ~/Applications/
open ~/Applications/"$APP"
echo "✅ Installiert: ~/Applications/$APP"
