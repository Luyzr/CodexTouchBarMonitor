#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_build_host.py
mkdir -p work/home work/cache work/tmp dist
export TMPDIR="$PWD/work/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/work/cache/clang"
swift build -c release -Xswiftc -debug-prefix-map -Xswiftc "$PWD=." -Xcc "-ffile-prefix-map=$PWD=." --scratch-path .build --cache-path "$PWD/work/cache/swift" --config-path "$PWD/work/config" --security-path "$PWD/work/security"
app="dist/CodexTouchBarMonitor.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/CodexTouchBarMonitor "$app/Contents/MacOS/"
strip -S "$app/Contents/MacOS/CodexTouchBarMonitor"
cp Resources/Info.plist "$app/Contents/Info.plist"
find "$app" -name '._*' -type f -delete
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
find "$app" -name '._*' -type f -delete
COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent "$app" dist/CodexTouchBarMonitor-arm64.zip
shasum -a 256 dist/CodexTouchBarMonitor-arm64.zip
