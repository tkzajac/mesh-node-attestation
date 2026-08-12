#!/usr/bin/env bash
# Generates an EMULATED offline root CA for testing only.
# Parameterized so it can be run once per path (istio-csr's root, SPIRE's
# root) instead of assuming a single shared root - see docs/COMPARISON.md
# for why the two paths in this repo each get their own fully independent
# root+intermediate.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <out-dir> <subject-cn>" >&2
  echo "  e.g.: $0 authority/istio 'istio-csr Test Root CA (EMULATED)'" >&2
  exit 1
fi

OUT_DIR="$1"
CN="$2"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

KEY_FILE="$OUT_DIR/root-ca.key"
CERT_FILE="$OUT_DIR/root-ca.crt"
SUBJECT="/CN=${CN}/O=mesh-node-attestation-test/C=US"
DAYS=3650
# pathlen:2 - chain is Root -> Intermediate -> the downstream CA that each
# path's authority issues at runtime (istio-csr's Issuer cert / SPIRE
# Server's own CA cert) -> leaf cert. Two CA certs sit between this root and
# any leaf.

if [[ -f "$KEY_FILE" || -f "$CERT_FILE" ]]; then
  echo "Refusing to overwrite existing root CA material in $OUT_DIR (found root-ca.key and/or root-ca.crt)." >&2
  echo "Remove them manually first if you really want to regenerate the emulated root." >&2
  exit 1
fi

openssl ecparam -name prime256v1 -genkey -noout -out "$KEY_FILE"
chmod 600 "$KEY_FILE"

openssl req -x509 -new -nodes \
  -key "$KEY_FILE" \
  -sha256 \
  -days "$DAYS" \
  -subj "$SUBJECT" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:2" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -addext "authorityKeyIdentifier=keyid:always,issuer" \
  -out "$CERT_FILE"

echo "Emulated root CA generated:"
echo "  key:  $KEY_FILE  (TEST ONLY - never commit, never use as a real trust root)"
echo "  cert: $CERT_FILE"
openssl x509 -in "$CERT_FILE" -noout -subject -dates
