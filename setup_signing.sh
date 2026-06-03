#!/usr/bin/env bash
# One-time setup: create a STABLE self-signed code-signing identity.
#
# Why: build.sh otherwise ad-hoc signs the app, which identifies the binary by its
# cdhash — a value that changes on every build. macOS Keychain ACLs (e.g. the
# "Always Allow" grant that lets CCCostMonitor read the Claude Code OAuth token) are
# tied to the app's code identity, so an ad-hoc app loses the grant on every rebuild
# and the Plan tab keeps disappearing until you re-authorize.
#
# A self-signed certificate gives the app a constant Designated Requirement (based on
# the cert, not the cdhash). Sign every build with the same cert → the Keychain grant
# is asked once and then persists across all future rebuilds.
#
# Run once per machine:  bash setup_signing.sh
set -euo pipefail

IDENTITY_NAME="CCCostMonitor Self-Signed"
LOGIN_KEYCHAIN="$(security default-keychain | tr -d ' "')"

if security find-certificate -c "$IDENTITY_NAME" >/dev/null 2>&1; then
    echo "✅ Signing identity '$IDENTITY_NAME' already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/codesign.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "🔑 Generating self-signed code-signing certificate (valid 10 years)..."
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/codesign.cnf" >/dev/null 2>&1

# OpenSSL 3.x defaults to PKCS#12 algorithms macOS `security import` rejects with
# "MAC verification failed". Pin the legacy SHA1/3DES PBE + SHA1 MAC the keychain
# accepts, and use a transient password (an empty p12 password also trips the MAC check).
P12_PASS="ccmonitor-transient"
openssl pkcs12 -export -legacy \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA1 \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY_NAME" -out "$TMP/identity.p12" -passout pass:"$P12_PASS" >/dev/null 2>&1

echo "📥 Importing into the login keychain (pre-authorizing codesign to use the key)..."
security import "$TMP/identity.p12" -k "$LOGIN_KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null 2>&1

echo "✅ Done. Identity '$IDENTITY_NAME' installed in $LOGIN_KEYCHAIN"
echo "   build.sh will now sign with it automatically."
echo "   On the FIRST build after this, if macOS asks whether codesign may use the"
echo "   key, click \"Always Allow\" once."
