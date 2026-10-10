#!/usr/bin/env bash
set -Eeu -o pipefail

# TaskPilot sends the Gemini API key over this script's standard input. Never add
# the key to this script's arguments, environment, progress events, or logs.
GEMINI_API_KEY=""
IFS= read -r GEMINI_API_KEY || true
if [[ -n "$GEMINI_API_KEY" && ${#GEMINI_API_KEY} -lt 20 ]]; then
  printf 'ORBIT_SETUP|error|Enter a complete Gemini API key from Google AI Studio.\n'
  exit 2
fi
has_gemini_api_key=0
if [[ -n "$GEMINI_API_KEY" ]]; then
  has_gemini_api_key=1
fi

emit() {
  printf 'ORBIT_SETUP|%s|%s\n' "$1" "$2"
}

fail() {
  emit "error" "$1"
  exit 1
}

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/orbit-openclaw.XXXXXX")"
command_log="$temporary_directory/command.log"
cleanup() {
  GEMINI_API_KEY=""
  unset GEMINI_API_KEY
  rm -rf "$temporary_directory"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

if [[ "${ORBIT_OPENCLAW_BOOTSTRAP_TEST:-0}" == "1" ]]; then
  GEMINI_API_KEY=""
  unset GEMINI_API_KEY
  emit "1.00" "OpenClaw automated setup test completed."
  exit 0
fi

find_openclaw() {
  local candidate
  for candidate in \
    "${ORBIT_OPENCLAW_PATH:-}" \
    "$HOME/.openclaw/bin/openclaw" \
    "$HOME/.local/bin/openclaw" \
    "$HOME/.npm-global/bin/openclaw" \
    "/opt/homebrew/bin/openclaw" \
    "/usr/local/bin/openclaw"
  do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if command -v openclaw >/dev/null 2>&1; then
    command -v openclaw
    return 0
  fi
  return 1
}

emit "0.05" "Checking this Mac for OpenClaw…"
openclaw_path="$(find_openclaw || true)"

requires_install=0
if [[ -z "$openclaw_path" ]]; then
  requires_install=1
else
  installed_version="$("$openclaw_path" --version 2>/dev/null || true)"
  if [[ "$installed_version" =~ ([0-9]{4})\.([0-9]+)\.([0-9]+) ]]; then
    installed_version_number=$((10#${BASH_REMATCH[1]} * 10000 + 10#${BASH_REMATCH[2]} * 100 + 10#${BASH_REMATCH[3]}))
    if [[ $installed_version_number -lt 20260905 ]]; then
      requires_install=1
      emit "0.10" "Updating OpenClaw and its private Node runtime for current Gemini models…"
    fi
  fi
fi

if [[ $requires_install -eq 1 ]]; then
  emit "0.12" "Downloading the official OpenClaw installer…"
  installer="$temporary_directory/install-cli.sh"
  if ! /usr/bin/curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 \
    "https://openclaw.ai/install-cli.sh" \
    --output "$installer" >"$command_log" 2>&1; then
    fail "Could not download OpenClaw. Check the internet connection and try again."
  fi

  emit "0.24" "Installing OpenClaw and its private Node runtime in ~/.openclaw…"
  if ! /bin/bash "$installer" --json --prefix "$HOME/.openclaw" --version latest \
    >"$command_log" 2>&1; then
    fail "The official OpenClaw installer failed. Use Open Terminal for the detailed recovery flow."
  fi
  openclaw_path="$HOME/.openclaw/bin/openclaw"
else
  emit "0.28" "Using the OpenClaw installation already on this Mac…"
fi

if [[ ! -x "$openclaw_path" ]]; then
  fail "OpenClaw finished installing, but its executable could not be found."
fi
if ! "$openclaw_path" config validate >"$command_log" 2>&1; then
  emit "0.34" "Migrating older OpenClaw configuration for the updated Gateway…"
  if ! "$openclaw_path" doctor --fix --non-interactive --yes >"$command_log" 2>&1 ||
     ! "$openclaw_path" config validate >"$command_log" 2>&1; then
    fail "OpenClaw's existing configuration needs repair. Run openclaw doctor --fix in Terminal, then retry."
  fi
fi

emit "0.38" "Creating OpenClaw’s local workspace and loopback configuration…"
if [[ ! -f "$HOME/.openclaw/openclaw.json" ]]; then
  if ! "$openclaw_path" setup --baseline >"$command_log" 2>&1; then
    fail "OpenClaw could not create its local workspace."
  fi
fi
if ! "$openclaw_path" config set gateway.mode local >"$command_log" 2>&1; then
  fail "OpenClaw could not select its local Gateway mode."
fi
if ! "$openclaw_path" config set gateway.bind loopback >"$command_log" 2>&1; then
  fail "OpenClaw could not restrict its Gateway to this Mac."
fi

if [[ $has_gemini_api_key -eq 0 ]]; then
  GEMINI_API_KEY=""
  unset GEMINI_API_KEY
  emit "installed" "OpenClaw and Node are installed. Add a Gemini API key later to enable Run."
  exit 10
fi

# The shared runtime synchronizes only TaskPilot-managed models and the
# supplied credential once; setup does not maintain a second model policy.
emit "0.78" "Installing and starting OpenClaw’s private loopback Gateway…"
if ! "$openclaw_path" gateway install --force >"$command_log" 2>&1; then
  fail "OpenClaw could not install its background Gateway service."
fi
"$openclaw_path" gateway restart >"$command_log" 2>&1 || true
gateway_ready=0
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if "$openclaw_path" health --json >"$command_log" 2>&1; then
    gateway_ready=1
    break
  fi
  sleep 1
done
if [[ $gateway_ready -ne 1 ]]; then
  fail "The OpenClaw Gateway did not become healthy. Open Terminal for recovery details."
fi
runtime="${ORBIT_RUNTIME_CHECK_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../AgentRuntime" && pwd)/orbit_openclaw_runtime}"
if [[ ! -x "$runtime" ]]; then
  fail "TaskPilot’s bundled ACP runtime is missing. Reinstall TaskPilot and retry."
fi
emit "0.90" "Verifying image input and JSON output through TaskPilot’s ACP client…"
# Gemini keys use base64url characters, so this JSON does not need shell interpolation escapes.
if [[ "$GEMINI_API_KEY" == *[!a-zA-Z0-9_-]* ]]; then
  fail "The Gemini API key contains unexpected characters. Check the saved key."
fi
if ! printf '{"kind":"runtime_configuration","gemini_api_key":"%s"}\n' "$GEMINI_API_KEY" | \
  "$runtime" --check-models --openclaw-path "$openclaw_path" >"$command_log" 2>&1; then
  # Emit the structured runtime result for the controller, without credentials.
  cat "$command_log"
  fail "TaskPilot’s ACP verification failed. Inspect the model error above and repair the key, configuration, or provider capacity."
fi
GEMINI_API_KEY=""
unset GEMINI_API_KEY

emit "0.97" "Confirming TaskPilot can discover the configured OpenClaw agent…"
if ! "$openclaw_path" agents list --json >"$command_log" 2>&1; then
  fail "OpenClaw is installed, but its agent inventory is not ready yet."
fi

emit "1.00" "OpenClaw is configured and verified through TaskPilot with image input and JSON output."
