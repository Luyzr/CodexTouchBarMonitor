#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_build_host.py
mkdir -p work/cache work/tmp
export TMPDIR="$PWD/work/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/work/cache/clang"
swift run --scratch-path .build --cache-path "$PWD/work/cache/swift" --config-path "$PWD/work/config" --security-path "$PWD/work/security" MonitorCoreTests

# Offline protocol and AppKit checks, with private Touch Bar calls disabled.
swift build --product CodexTouchBarMonitor --scratch-path .build --cache-path "$PWD/work/cache/swift" --config-path "$PWD/work/config" --security-path "$PWD/work/security"
.build/debug/CodexTouchBarMonitor --self-check
.build/debug/CodexTouchBarMonitor --ui-check --disable-private-api
if [[ "${1:-}" == "--live" ]]; then
    .build/debug/CodexTouchBarMonitor --probe-daemon
fi
