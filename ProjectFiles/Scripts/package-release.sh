#!/usr/bin/env bash
set -euo pipefail

# Creates a distribution package that Gatekeeper can accept after notarization.
# This script intentionally has no ad-hoc-signing fallback: an ad-hoc build is
# suitable for local development, but cannot make a downloaded app trusted.

APP_NAME="TaskPilot"
PROCESS_NAME="OrbitAgent"
BUNDLE_ID="com.orbitagent.controller"
PROJECT_FILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$PROJECT_FILES_DIR/.." && pwd)"
BUILD_SCRIPT="$PROJECT_FILES_DIR/Scripts/build-and-run.sh"
APP_BUNDLE="$PROJECT_ROOT/$APP_NAME.app"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/dist}"
CODE_SIGN_IDENTITY_VALUE="${CODE_SIGN_IDENTITY:-}"
CODE_SIGN_KEYCHAIN_VALUE="${CODE_SIGN_KEYCHAIN:-}"
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-}"

fail() {
  echo "package-release: $1" >&2
  exit 64
}

[[ -n "$CODE_SIGN_IDENTITY_VALUE" ]] || fail \
  "set CODE_SIGN_IDENTITY to a Developer ID Application identity."
[[ -n "$NOTARY_PROFILE" ]] || fail \
  "set NOTARYTOOL_PROFILE to an xcrun notarytool keychain profile."

IDENTITY_RECORD="$(security find-identity -p codesigning -v | \
  grep -F "$CODE_SIGN_IDENTITY_VALUE" | head -n 1 || true)"
[[ -n "$IDENTITY_RECORD" ]] || fail \
  "CODE_SIGN_IDENTITY is not an available codesigning identity."
[[ "$IDENTITY_RECORD" == *"Developer ID Application"* ]] || fail \
  "only a Developer ID Application identity can produce a distributable app; refusing ad-hoc or local certificates."

xcrun notarytool --help >/dev/null 2>&1 || fail \
  "xcrun notarytool is unavailable; install Xcode Command Line Tools."

if [[ -n "$CODE_SIGN_KEYCHAIN_VALUE" ]]; then
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY_VALUE" \
  CODE_SIGN_KEYCHAIN="$CODE_SIGN_KEYCHAIN_VALUE" \
  ORBIT_HARDENED_RUNTIME=1 \
  "$BUILD_SCRIPT" --build-only
else
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY_VALUE" \
  ORBIT_HARDENED_RUNTIME=1 \
  "$BUILD_SCRIPT" --build-only
fi

[[ -d "$APP_BUNDLE" ]] || fail "the build did not produce $APP_BUNDLE."

mkdir -p "$OUTPUT_DIR"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - \
  "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || printf 'unknown')"
ARCH="$(uname -m)"
STAGING_DIR="$(mktemp -d "$PROJECT_FILES_DIR/.taskpilot-build/release.XXXXXX")"
PRE_NOTARIZATION_ZIP="$STAGING_DIR/$APP_NAME-$VERSION-macOS-$ARCH.zip"
FINAL_ZIP="$OUTPUT_DIR/$APP_NAME-$VERSION-macOS-$ARCH.zip"

[[ ! -e "$FINAL_ZIP" ]] || fail "refusing to overwrite existing output: $FINAL_ZIP"

# Re-sign the completed bundle with the hardened runtime. The build script
# already signs nested code; this final pass makes the release intent explicit.
SIGNING_ARGS=(--force --deep --options runtime --timestamp)
if [[ -n "$CODE_SIGN_KEYCHAIN_VALUE" ]]; then
  SIGNING_ARGS+=(--keychain "$CODE_SIGN_KEYCHAIN_VALUE")
fi
SIGNING_ARGS+=(--sign "$CODE_SIGN_IDENTITY_VALUE" "$APP_BUNDLE")
codesign "${SIGNING_ARGS[@]}"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$PRE_NOTARIZATION_ZIP"
xcrun notarytool submit "$PRE_NOTARIZATION_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

xcrun stapler staple -v "$APP_BUNDLE"
xcrun stapler validate -v "$APP_BUNDLE"
spctl -a -vv --type execute "$APP_BUNDLE"

ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$FINAL_ZIP"
echo "Created notarized package: $FINAL_ZIP"
