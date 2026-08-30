#!/usr/bin/env bash
set -euo pipefail

PROJECT_FILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_DIR="${ORBIT_SIGNING_DIR:-$PROJECT_FILES_DIR/.taskpilot-build/local-signing}"
KEYCHAIN="$SIGNING_DIR/OrbitAgentSigning.keychain-db"
PASSWORD_FILE="$SIGNING_DIR/keychain-password"
PRIVATE_KEY="$SIGNING_DIR/orbit-agent-signing.key"
CERTIFICATE="$SIGNING_DIR/orbit-agent-signing.crt"
IDENTITY_BUNDLE="$SIGNING_DIR/orbit-agent-signing.p12"
IDENTITY_NAME="Orbit Agent Local Development"

mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"

if [[ ! -s "$PASSWORD_FILE" ]]; then
  umask 077
  openssl rand -base64 36 >"$PASSWORD_FILE"
fi
chmod 600 "$PASSWORD_FILE"
KEYCHAIN_PASSWORD="$(<"$PASSWORD_FILE")"

if [[ ! -s "$PRIVATE_KEY" || ! -s "$CERTIFICATE" || ! -s "$IDENTITY_BUNDLE" ]]; then
  umask 077
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes \
    -days 3650 \
    -subj "/CN=$IDENTITY_NAME/O=Orbit Agent Local Development" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$PRIVATE_KEY" \
    -out "$CERTIFICATE"
  openssl pkcs12 -export \
    -legacy \
    -name "$IDENTITY_NAME" \
    -inkey "$PRIVATE_KEY" \
    -in "$CERTIFICATE" \
    -out "$IDENTITY_BUNDLE" \
    -passout "pass:$KEYCHAIN_PASSWORD"
fi

if [[ ! -f "$KEYCHAIN" ]]; then
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
fi

security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"

if ! security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  security import "$IDENTITY_BUNDLE" \
    -k "$KEYCHAIN" \
    -P "$KEYCHAIN_PASSWORD" \
    -T /usr/bin/codesign >/dev/null
fi

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN" >/dev/null

CERTIFICATE_SHA1="$(security find-certificate -c "$IDENTITY_NAME" -Z "$KEYCHAIN" | awk '/SHA-1 hash:/ { print $3; exit }')"
if [[ -z "$CERTIFICATE_SHA1" ]]; then
  echo "Unable to locate the Orbit Agent local signing identity." >&2
  exit 1
fi

if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -Fq "$CERTIFICATE_SHA1"; then
  cat >&2 <<MESSAGE
The Orbit Agent local certificate exists but is not trusted for code signing.
Trust only $CERTIFICATE for the codeSign policy, then run this script again.
MESSAGE
  exit 1
fi

KEYCHAIN_REGISTERED=0
KEYCHAIN_SEARCH_LIST=()
while IFS= read -r KEYCHAIN_ENTRY; do
  KEYCHAIN_ENTRY="${KEYCHAIN_ENTRY#*\"}"
  KEYCHAIN_ENTRY="${KEYCHAIN_ENTRY%\"*}"
  [[ -z "$KEYCHAIN_ENTRY" ]] && continue
  KEYCHAIN_SEARCH_LIST+=("$KEYCHAIN_ENTRY")
  if [[ "$KEYCHAIN_ENTRY" == "$KEYCHAIN" ]]; then
    KEYCHAIN_REGISTERED=1
  fi
done < <(security list-keychains -d user)

if [[ "$KEYCHAIN_REGISTERED" == "0" ]]; then
  security list-keychains -d user -s "${KEYCHAIN_SEARCH_LIST[@]}" "$KEYCHAIN"
fi

printf '%s\n%s\n' "$CERTIFICATE_SHA1" "$KEYCHAIN"
