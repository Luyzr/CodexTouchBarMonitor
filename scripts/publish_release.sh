#!/bin/bash
# Explicit operator action only. All compilation remains in the guarded configured remote build script.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_build_host.py
command -v gh >/dev/null || { echo 'Install/authenticate GitHub CLI before publishing'; exit 1; }
python3 scripts/prepare_release.py
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
test -z "$(git status --porcelain)" || { echo 'Commit the reviewed source before publishing'; exit 1; }
test "$(git rev-parse "v$version^{commit}")" = "$(git rev-parse HEAD)" || { echo 'Create the reviewed version tag at HEAD first'; exit 1; }
gh release create "v$version" --repo Luyzr/CodexTouchBarMonitor --verify-tag --draft \
  --title "Codex TouchBar Monitor $version" --notes-file "docs/RELEASE-NOTES-$version.md" \
  dist/CodexTouchBarMonitor-arm64.zip dist/SHA256SUMS dist/codex-touchbar-monitor.rb
