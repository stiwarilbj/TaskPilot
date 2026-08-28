#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="TaskPilot"
PROCESS_NAME="OrbitAgent"
BUNDLE_ID="com.orbitagent.controller"
MIN_SYSTEM_VERSION="14.0"
LOCAL_SIGNING_MARKER="6C2A812B-5978-4E6A-9CA1-7DB0D7D6E947"
STABLE_ADHOC_REQUIREMENT="=designated => identifier \"$BUNDLE_ID\" and info[OrbitLocalSigningMarker] = \"$LOCAL_SIGNING_MARKER\""

PROJECT_FILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$PROJECT_FILES_DIR/.." && pwd)"
PACKAGE_ROOT="$PROJECT_FILES_DIR"
WORK_DIR="$PROJECT_FILES_DIR/.taskpilot-build"
BUILD_DIR="$WORK_DIR/swift-build"
MODULE_CACHE="$WORK_DIR/swiftpm-module-cache"
CLANG_CACHE="$WORK_DIR/clang-module-cache"
APP_BUNDLE="$PROJECT_ROOT/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
RUNTIME_SOURCE="$WORK_DIR/openclaw-runtime-dist/orbit_openclaw_runtime"
RUNTIME_DESTINATION="$APP_RESOURCES/AgentRuntime"
OPENCLAW_RESOURCES="$PROJECT_FILES_DIR/Resources/OpenClaw"

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true

mkdir -p "$WORK_DIR" "$MODULE_CACHE" "$CLANG_CACHE"

export CLANG_MODULE_CACHE_PATH="$CLANG_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

swift build --package-path "$PACKAGE_ROOT" --disable-sandbox --scratch-path "$BUILD_DIR"
BUILD_BINARY="$(swift build --package-path "$PACKAGE_ROOT" --disable-sandbox --scratch-path "$BUILD_DIR" --show-bin-path)/$PROCESS_NAME"

if [[ ! -x "$RUNTIME_SOURCE/orbit_openclaw_runtime" \
      || "$PROJECT_FILES_DIR/AgentRuntime/openclaw_runtime.py" -nt "$RUNTIME_SOURCE/orbit_openclaw_runtime" \
      || "$PROJECT_FILES_DIR/AgentRuntime/requirements.txt" -nt "$RUNTIME_SOURCE/orbit_openclaw_runtime" ]]; then
  "$PROJECT_FILES_DIR/Scripts/build-openclaw-runtime.sh"
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp -R "$RUNTIME_SOURCE" "$RUNTIME_DESTINATION"
cp -R "$OPENCLAW_RESOURCES" "$APP_RESOURCES/OpenClaw"
chmod +x \
  "$APP_BINARY" \
  "$RUNTIME_DESTINATION/orbit_openclaw_runtime" \
  "$APP_RESOURCES/OpenClaw/openclaw-setup.command" \
  "$APP_RESOURCES/OpenClaw/taskpilot-openclaw-bootstrap.sh"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$PROCESS_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>2.9.0</string>
  <key>CFBundleVersion</key>
  <string>290</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>OrbitLocalSigningMarker</key>
  <string>$LOCAL_SIGNING_MARKER</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSScreenCaptureUsageDescription</key>
  <string>TaskPilot captures application, window, and display pixels on its assigned screen so it can understand and complete your task.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>TaskPilot accesses Desktop files only when your task asks it to read, write, organize, or open them.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>TaskPilot accesses Documents only when your task asks it to read, write, organize, or open them.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>TaskPilot accesses Downloads only when your task asks it to read, write, organize, or open them.</string>
  <key>NSNetworkVolumesUsageDescription</key>
  <string>TaskPilot accesses a network volume only when your task explicitly requires a file there.</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>TaskPilot accesses a removable volume only when your task explicitly requires a file there.</string>
</dict>
</plist>
PLIST

USED_STABLE_ADHOC=0
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --deep --sign "$CODE_SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null
elif [[ "${ORBIT_LOCAL_CERT_SIGN:-0}" == "1" ]]; then
  SIGNING_CONFIGURATION="$("$PROJECT_FILES_DIR/Scripts/setup-local-signing.sh")"
  SIGNING_IDENTITY="${SIGNING_CONFIGURATION%%$'\n'*}"
  SIGNING_KEYCHAIN="${SIGNING_CONFIGURATION#*$'\n'}"
  codesign --force --deep --timestamp=none \
    --keychain "$SIGNING_KEYCHAIN" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE" >/dev/null
else
  # A default ad-hoc signature normally identifies the app by its changing
  # binary hash. TCC then leaves Accessibility and Screen Recording attached
  # to an older build after every update. This explicit requirement gives all
  # TaskPilot local builds the same scoped identity without trusting a new root
  # certificate or weakening the system trust store.
  codesign --force --deep --sign - \
    --requirements "$STABLE_ADHOC_REQUIREMENT" \
    "$APP_BUNDLE" >/dev/null
  USED_STABLE_ADHOC=1
fi

if [[ "$USED_STABLE_ADHOC" == "1" ]]; then
  DESIGNATED_REQUIREMENT="$(codesign -dr - "$APP_BUNDLE" 2>&1)"
  if [[ "$DESIGNATED_REQUIREMENT" == *"cdhash"* ||
        "$DESIGNATED_REQUIREMENT" != *"$LOCAL_SIGNING_MARKER"* ]]; then
    echo "TaskPilot's stable local signing requirement was not embedded." >&2
    exit 1
  fi
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$PROCESS_NAME" >/dev/null
    ;;
  --build-only|build-only)
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--build-only]" >&2
    exit 2
    ;;
esac
