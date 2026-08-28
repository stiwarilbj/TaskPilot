#!/usr/bin/env bash
set -euo pipefail

PROJECT_FILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SUPPORT_DIR="$PROJECT_FILES_DIR/.taskpilot-build"
VENV_DIR="${ORBIT_BUILD_VENV:-$BUILD_SUPPORT_DIR/runtime-build-venv}"
DIST_DIR="$BUILD_SUPPORT_DIR/openclaw-runtime-dist"
BUILD_DIR="$BUILD_SUPPORT_DIR/pyinstaller-build"
SPEC_DIR="$BUILD_SUPPORT_DIR/pyinstaller-spec"
CONFIG_DIR="$BUILD_SUPPORT_DIR/pyinstaller-config"
PYTHON="${ORBIT_BUILD_PYTHON:-/opt/homebrew/bin/python3.11}"

mkdir -p "$CONFIG_DIR"
export PYINSTALLER_CONFIG_DIR="$CONFIG_DIR"

if [[ ! -x "$PYTHON" ]]; then
  echo "Python 3.11 is required to build the bundled OpenClaw bridge: $PYTHON" >&2
  exit 1
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  "$PYTHON" -m venv "$VENV_DIR"
fi

if ! "$VENV_DIR/bin/python" -c 'import PyInstaller' >/dev/null 2>&1; then
  "$VENV_DIR/bin/python" -m pip install --disable-pip-version-check pyinstaller
fi

"$VENV_DIR/bin/pyinstaller" \
  --noconfirm \
  --clean \
  --onedir \
  --name orbit_openclaw_runtime \
  --distpath "$DIST_DIR" \
  --workpath "$BUILD_DIR" \
  --specpath "$SPEC_DIR" \
  "$PROJECT_FILES_DIR/AgentRuntime/openclaw_runtime.py"

test -x "$DIST_DIR/orbit_openclaw_runtime/orbit_openclaw_runtime"
