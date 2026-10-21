#!/bin/bash
# One-time setup: creates a self-signed code-signing identity in the login keychain so rebuilt
# timer-desk binaries keep the same signature identity and macOS keeps their privacy grants.
# The trust step asks for your login password.
set -eu
NAME="cofo-desk-auto local signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Identity \"$NAME\" already exists."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/req.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/req.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/identity.p12" -passout pass:import
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P import -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

security find-identity -v -p codesigning | grep "$NAME"
