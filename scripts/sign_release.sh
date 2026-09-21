#!/bin/bash
# Optional Developer ID signing/notarization for an already-built app. No credentials in source.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_build_host.py
: "${SIGNING_IDENTITY:?Set a Developer ID identity already installed in Keychain}"
app=dist/CodexTouchBarMonitor.app
find "$app" -name '._*' -type f -delete
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$app"
codesign --verify --deep --strict "$app"
find "$app" -name '._*' -type f -delete
COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent "$app" dist/CodexTouchBarMonitor-arm64.zip
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit dist/CodexTouchBarMonitor-arm64.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"
  find "$app" -name '._*' -type f -delete
  COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent "$app" dist/CodexTouchBarMonitor-arm64.zip
fi
python3 scripts/prepare_release.py
