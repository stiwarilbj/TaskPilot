#!/bin/zsh
set -u

for candidate in \
  "${ORBIT_OPENCLAW_PATH:-}" \
  "$HOME/.openclaw/bin/openclaw" \
  /opt/homebrew/bin/openclaw \
  /usr/local/bin/openclaw \
  "$HOME/.local/bin/openclaw" \
  "$HOME/.npm-global/bin/openclaw"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    echo "TaskPilot is opening OpenClaw setup."
    echo
    exec "$candidate" setup
  fi
done

if command -v openclaw >/dev/null 2>&1; then
  exec openclaw setup
fi

echo "OpenClaw was not found. Install it from:"
echo "https://docs.openclaw.ai/install"
echo
read -r "?Press Return to close."
