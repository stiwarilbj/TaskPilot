#!/usr/bin/env bash
set -euo pipefail

root_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/orbit-openclaw-bootstrap-test.XXXXXX")"
cleanup() {
  rm -rf "$test_directory"
}
trap cleanup EXIT

mkdir -p "$test_directory/home/.openclaw"
touch "$test_directory/home/.openclaw/openclaw.json"
mock_log="$test_directory/openclaw-arguments.log"
mock_openclaw="$root_directory/Tests/Fixtures/mock_openclaw.sh"
test_key="AIzaSyOrbitMockGeminiKey1234567890"

setup_output="$(
  printf '%s\n' "$test_key" | \
    HOME="$test_directory/home" \
    ORBIT_OPENCLAW_PATH="$mock_openclaw" \
    ORBIT_MOCK_OPENCLAW_LOG="$mock_log" \
    /bin/bash "$root_directory/Resources/OpenClaw/taskpilot-openclaw-bootstrap.sh"
)"

if /usr/bin/grep -qF "$test_key" "$mock_log"; then
  echo "Gemini key leaked into OpenClaw arguments" >&2
  exit 1
fi

/usr/bin/grep -qF "credential-bytes=${#test_key}" "$mock_log"
/usr/bin/grep -qF "models set google/gemini-3.5-flash" "$mock_log"
/usr/bin/grep -qF "models fallbacks add google/gemini-3-flash-preview" "$mock_log"
/usr/bin/grep -qF "models fallbacks add google/gemini-3.1-flash-lite" "$mock_log"
/usr/bin/grep -qF "models fallbacks add google/gemini-2.5-flash" "$mock_log"
/usr/bin/grep -qF "models fallbacks add google/gemini-2.5-flash-lite" "$mock_log"
/usr/bin/grep -qF "models set-image google/gemini-3.5-flash" "$mock_log"
fallback_order="$(/usr/bin/grep '^models fallbacks add ' "$mock_log")"
expected_fallback_order=$'models fallbacks add google/gemini-3-flash-preview\nmodels fallbacks add google/gemini-3.1-flash-lite\nmodels fallbacks add google/gemini-2.5-flash\nmodels fallbacks add google/gemini-2.5-flash-lite'
if [[ "$fallback_order" != "$expected_fallback_order" ]]; then
  echo "OpenClaw text fallback order does not match TaskPilot's quota router" >&2
  exit 1
fi
/usr/bin/grep -qF "gateway install --force" "$mock_log"
/usr/bin/grep -qF "agent --agent main --message Reply with exactly ORBIT_OPENCLAW_READY --json --timeout 120" "$mock_log"
/usr/bin/grep -qF "ORBIT_SETUP|1.00|OpenClaw is installed, configured, running, and verified with Gemini." <<<"$setup_output"

no_key_home="$test_directory/no-key-home"
no_key_log="$test_directory/no-key-openclaw-arguments.log"
mkdir -p "$no_key_home/.openclaw"
touch "$no_key_home/.openclaw/openclaw.json"
set +e
no_key_output="$(
  printf '\n' | \
    HOME="$no_key_home" \
    ORBIT_OPENCLAW_PATH="$mock_openclaw" \
    ORBIT_MOCK_OPENCLAW_LOG="$no_key_log" \
    /bin/bash "$root_directory/Resources/OpenClaw/taskpilot-openclaw-bootstrap.sh"
)"
no_key_status=$?
set -e

if [[ $no_key_status -ne 10 ]]; then
  echo "Keyless OpenClaw installation returned $no_key_status instead of 10" >&2
  exit 1
fi
/usr/bin/grep -qF "ORBIT_SETUP|installed|OpenClaw and Node are installed." <<<"$no_key_output"
if /usr/bin/grep -qE 'models auth|models set|gateway install|agent --agent' "$no_key_log"; then
  echo "Keyless OpenClaw installation attempted Gemini or Gateway configuration" >&2
  exit 1
fi

echo "OpenClaw bootstrap mock integration passed"
