#!/usr/bin/env bash
# Creates the local self-signed code-signing identity Murmur is signed with.
#
# Why this exists: an ad-hoc signature is derived from the binary's contents, so
# every rebuild produces a new code hash. macOS pins Accessibility grants to that
# hash, so after a rebuild the Settings toggle still shows "on" while the system
# no longer matches the running app to it. Nothing works and nothing explains why.
#
# Signing with a stable certificate makes the designated requirement
#   identifier "com.yahyaelghobashy.murmur" and certificate root = H"..."
# which does not change when the binary does. The grant then survives rebuilds.
set -euo pipefail
NAME="Murmur Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "identity already present: $NAME"; exit 0
fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/ext.cnf" <<'CNF'
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -keyout "$T/key.pem" -out "$T/cert.pem" -days 3650 -nodes \
  -subj "/CN=$NAME/O=Yahya Elghobashy" \
  -extensions v3 -config <(cat /etc/ssl/openssl.cnf "$T/ext.cnf") 2>/dev/null
# Legacy PBE + SHA1 MAC: OpenSSL 3's defaults are unreadable by macOS Security.
openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" \
  -passout pass:murmur -name "$NAME" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
security import "$T/id.p12" -k ~/Library/Keychains/login.keychain-db -P murmur -T /usr/bin/codesign -A
cp "$T/cert.pem" "$(dirname "$0")/murmur-signing.pem"
echo "created: $NAME"
echo "note: 'security find-identity -p codesigning' will still show 0, because the"
echo "cert is not in the trust store. codesign uses it regardless, which is all we need."
