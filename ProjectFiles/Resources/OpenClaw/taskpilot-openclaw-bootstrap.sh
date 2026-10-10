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

emit "0.48" "Saving the Gemini credential in OpenClaw’s credential store…"
if ! printf '%s\n' "$GEMINI_API_KEY" | \
  "$openclaw_path" models auth paste-api-key \
    --provider google --profile-id google:orbit >"$command_log" 2>&1; then
  fail "OpenClaw rejected the Gemini API key. Check the key and try again."
fi
model_candidates=(
  "google/gemini-3.5-flash-lite"
  "google/gemini-3.1-flash-lite"
  "google/gemini-2.5-flash-lite"
  "google/gemini-3.8-flash"
  "google/gemini-3-flash-preview"
  "google/gemini-2.5-flash"
)
model_allowlist="["
for model in "${model_candidates[@]}"; do
  if [[ "$model_allowlist" != "[" ]]; then
    model_allowlist+=","
  fi
  model_allowlist+="\"$model\""
done
model_allowlist+="]"
if ! "$openclaw_path" config set agents.defaults.modelPolicy.allow \
  "$model_allowlist" --strict-json --replace >"$command_log" 2>&1; then
  fail "OpenClaw could not allow the requested Gemini models for TaskPilot."
fi
probe="${ORBIT_GEMINI_PROBE_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gemini-probe.py}"
if ! command -v python3 >/dev/null 2>&1 || [[ ! -f "$probe" ]]; then
  fail "Gemini verification needs Python 3 and the bundled model probe. Reinstall TaskPilot and try again."
fi
emit "0.54" "Checking which Gemini model actually responds with this key…"
configure_model_chain() {
  local candidate="$1" model
  local fallbacks=()
  for model in "${model_candidates[@]}"; do
    if [[ "$model" != "$candidate" ]]; then
      fallbacks+=("$model")
    fi
  done
  if ! "$openclaw_path" models set "$candidate" >"$command_log" 2>&1; then
    fail "OpenClaw could not select ${candidate#google/}."
  fi
  if ! "$openclaw_path" models fallbacks clear >"$command_log" 2>&1; then
    fail "OpenClaw could not reset the text-model fallback list."
  fi
  for model in "${fallbacks[@]}"; do
    if ! "$openclaw_path" models fallbacks add "$model" >"$command_log" 2>&1; then
      fail "OpenClaw could not add ${model#google/} to the text fallback list."
    fi
  done
  if ! "$openclaw_path" models set-image "$candidate" >"$command_log" 2>&1; then
    fail "OpenClaw could not select the image-aware Gemini primary model."
  fi
  if ! "$openclaw_path" models image-fallbacks clear >"$command_log" 2>&1; then
    fail "OpenClaw could not reset the image-model fallback list."
  fi
  for model in "${fallbacks[@]}"; do
    if ! "$openclaw_path" models image-fallbacks add "$model" >"$command_log" 2>&1; then
      fail "OpenClaw could not add ${model#google/} to the image fallback list."
    fi
  done
}

set -- # Positional parameters track models that failed Gateway verification.
gateway_installed=0
gateway_verified=0
while [[ $# -lt ${#model_candidates[@]} ]]; do
  if ! primary_model="$(printf '%s\n' "$GEMINI_API_KEY" | python3 "$probe" "$@")"; then
    fail "$primary_model"
  fi
  emit "0.58" "Using ${primary_model#google/} as the responsive primary model…"
  configure_model_chain "$primary_model"

  if [[ $gateway_installed -eq 0 ]]; then
    emit "0.78" "Installing and starting OpenClaw’s private loopback Gateway…"
    if ! "$openclaw_path" gateway install --force >"$command_log" 2>&1; then
      fail "OpenClaw could not install its background Gateway service."
    fi
    gateway_installed=1
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

  emit "0.90" "Verifying ${primary_model#google/} through OpenClaw’s Gateway…"
  if "$openclaw_path" agent --agent main \
    --model "$primary_model" \
    --session-id "taskpilot-setup-$(date +%s)-$#" \
    --message "Reply with exactly ORBIT_OPENCLAW_READY" \
    --json --timeout 120 >"$command_log" 2>&1; then
    if /usr/bin/grep -q "ORBIT_OPENCLAW_READY" "$command_log"; then
      gateway_verified=1
      break
    fi
    fail "OpenClaw returned a reply from ${primary_model#google/}, but it did not contain the expected verification text."
  fi
  if /usr/bin/grep -Eqi 'api key not valid|invalid api key|invalid credential' "$command_log"; then
    fail "OpenClaw could not use the Gemini API key. Check the key and its permissions in Google AI Studio."
  fi
  if /usr/bin/grep -Eqi 'high demand|temporarily overloaded|RESOURCE_EXHAUSTED|quota|rate.limit|HTTP 429|HTTP 503|HTTP 403|permission denied|forbidden|unauthorized' "$command_log"; then
    set -- "$@" "$primary_model"
    emit "0.90" "${primary_model#google/} was unavailable through OpenClaw; trying another Gemini model…"
    continue
  fi
  fail "Google answered the direct model check, but OpenClaw's Gateway request failed. Open Terminal to inspect the Gateway configuration, then retry."
done
GEMINI_API_KEY=""
unset GEMINI_API_KEY
if [[ $gateway_verified -ne 1 ]]; then
  fail "Every Gemini model tried through OpenClaw hit a demand or quota limit. Wait for capacity to recover, then run setup again."
fi

emit "0.97" "Confirming TaskPilot can discover the configured OpenClaw agent…"
if ! "$openclaw_path" agents list --json >"$command_log" 2>&1; then
  fail "OpenClaw is installed, but its agent inventory is not ready yet."
fi

emit "1.00" "OpenClaw is installed, configured, running, and verified with Gemini."
