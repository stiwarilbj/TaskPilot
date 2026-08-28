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

if [[ -z "$openclaw_path" ]]; then
  emit "0.12" "Downloading the official OpenClaw installer…"
  installer="$temporary_directory/install-cli.sh"
  if ! /usr/bin/curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 \
    "https://openclaw.ai/install-cli.sh" \
    --output "$installer" >"$command_log" 2>&1; then
    fail "Could not download OpenClaw. Check the internet connection and try again."
  fi

  emit "0.24" "Installing OpenClaw and its private Node runtime in ~/.openclaw…"
  if ! /bin/bash "$installer" --json --prefix "$HOME/.openclaw" \
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
GEMINI_API_KEY=""
unset GEMINI_API_KEY

primary_model="google/gemini-3.5-flash"
fallback_models=(
  "google/gemini-3-flash-preview"
  "google/gemini-3.1-flash-lite"
  "google/gemini-2.5-flash"
  "google/gemini-2.5-flash-lite"
)

emit "0.58" "Configuring TaskPilot’s five-model Gemini rotation…"
if ! "$openclaw_path" models set "$primary_model" >"$command_log" 2>&1; then
  fail "OpenClaw could not select gemini-3.5-flash."
fi
if ! "$openclaw_path" models fallbacks clear >"$command_log" 2>&1; then
  fail "OpenClaw could not reset the text-model fallback list."
fi
for model in "${fallback_models[@]}"; do
  if ! "$openclaw_path" models fallbacks add "$model" >"$command_log" 2>&1; then
    fail "OpenClaw could not add ${model#google/} to the text fallback list."
  fi
done

emit "0.68" "Applying the same Gemini order to image-aware requests…"
if ! "$openclaw_path" models set-image "$primary_model" >"$command_log" 2>&1; then
  fail "OpenClaw could not select the image-aware Gemini primary model."
fi
if ! "$openclaw_path" models image-fallbacks clear >"$command_log" 2>&1; then
  fail "OpenClaw could not reset the image-model fallback list."
fi
for model in "${fallback_models[@]}"; do
  if ! "$openclaw_path" models image-fallbacks add "$model" >"$command_log" 2>&1; then
    fail "OpenClaw could not add ${model#google/} to the image fallback list."
  fi
done

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

emit "0.90" "Verifying the model chain with a real Gemini request…"
if ! "$openclaw_path" agent --agent main \
  --message "Reply with exactly ORBIT_OPENCLAW_READY" \
  --json --timeout 120 >"$command_log" 2>&1; then
  fail "Gemini did not complete the verification request. Check the API key, model access, quota, and internet connection."
fi
if ! /usr/bin/grep -q "ORBIT_OPENCLAW_READY" "$command_log"; then
  fail "Gemini replied, but OpenClaw could not verify the expected response."
fi

emit "0.97" "Confirming TaskPilot can discover the configured OpenClaw agent…"
if ! "$openclaw_path" agents list --json >"$command_log" 2>&1; then
  fail "OpenClaw is installed, but its agent inventory is not ready yet."
fi

emit "1.00" "OpenClaw is installed, configured, running, and verified with Gemini."
