#!/bin/bash
set -euo pipefail
ROOT="${1:-${TMPDIR:-/tmp}/forge-codesign-$RANDOM}"
mkdir -p "$ROOT"
KEYCHAIN="$ROOT/forge-test.keychain-db"
PASSWORD="$(/usr/bin/uuidgen | tr -d '-')"
SUBJECT="/CN=Forge Conductor Local Test Signing/"
/usr/bin/security create-keychain -p "$PASSWORD" "$KEYCHAIN"
/usr/bin/security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
/usr/bin/security set-keychain-settings -lut 21600 "$KEYCHAIN"
/usr/bin/openssl req -new -newkey rsa:2048 -x509 -days 2 -nodes -subj "$SUBJECT" -keyout "$ROOT/key.pem" -out "$ROOT/cert.pem" -addext keyUsage=digitalSignature -addext extendedKeyUsage=codeSigning
/usr/bin/openssl pkcs12 -export -out "$ROOT/identity.p12" -inkey "$ROOT/key.pem" -in "$ROOT/cert.pem" -passout pass:"$PASSWORD"
/usr/bin/security import "$ROOT/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
/usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
IDENTITY="$(/usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" | awk -F'\"' '/Forge Conductor Local Test Signing/{print $2; exit}')"
cat > "$ROOT/environment.sh" <<EOF
export FORGE_TEST_KEYCHAIN='$KEYCHAIN'
export FORGE_TEST_KEYCHAIN_PASSWORD='$PASSWORD'
export FORGE_TEST_CODESIGN_IDENTITY='$IDENTITY'
EOF
chmod 600 "$ROOT/environment.sh"
rm -f "$ROOT/key.pem" "$ROOT/identity.p12"
printf '%s\n' "$ROOT/environment.sh"
