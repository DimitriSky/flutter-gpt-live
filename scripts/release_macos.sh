#!/bin/zsh
# Builds the Release macOS app, signs it with a Developer ID (hardened runtime,
# secure timestamp), verifies it and copies "GPT Live.app" to OUT_DIR.
# The Debug flavor ("GPT Live Dev", own bundle id) is never touched.
#
#   SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
#   DEFINES=../artifacts/macos-defines.json scripts/release_macos.sh
set -euo pipefail
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to a 'Developer ID Application: …' identity}"
ROOT=${0:A:h:h}
OUT_DIR=${OUT_DIR:-$HOME/Downloads}
cd "$ROOT/app"

# A clean Release product avoids stale nested code from incremental builds.
rm -rf build/macos/Build/Products/Release build/macos/Build/Intermediates.noindex/Runner.build/Release
flutter build macos --release ${DEFINES:+--dart-define-from-file=$DEFINES}
APP="build/macos/Build/Products/Release/GPT Live.app"

# Sign nested code first, then the app with its sandbox entitlements.
for item in "$APP"/Contents/Frameworks/*.framework(N) "$APP"/Contents/Frameworks/*.dylib(N); do
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$item"
done
codesign --force --options runtime --timestamp \
  --entitlements macos/Runner/Release.entitlements --sign "$SIGN_IDENTITY" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
python3 "$ROOT/scripts/check_macos_release.py" "$APP"

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/GPT Live.app"
ditto "$APP" "$OUT_DIR/GPT Live.app"
codesign --verify --deep --strict "$OUT_DIR/GPT Live.app"
echo "Release ready: $OUT_DIR/GPT Live.app"
