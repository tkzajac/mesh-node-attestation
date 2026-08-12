#!/usr/bin/env bash
# Signs an intermediate CA CSR with the emulated root CA in the same out-dir.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <out-dir>" >&2
  echo "  e.g.: $0 authority/istio" >&2
  echo "  expects <out-dir>/root-ca.{key,crt} and <out-dir>/intermediate.csr to already exist." >&2
  exit 1
fi

OUT_DIR="$(cd "$1" && pwd)"
ROOT_KEY="$OUT_DIR/root-ca.key"
ROOT_CERT="$OUT_DIR/root-ca.crt"
CSR_FILE="$OUT_DIR/intermediate.csr"
DAYS=1825

if [[ ! -f "$ROOT_KEY" || ! -f "$ROOT_CERT" ]]; then
  echo "Emulated root CA not found in $OUT_DIR - run generate-root.sh first." >&2
  exit 1
fi

if [[ ! -f "$CSR_FILE" ]]; then
  echo "Intermediate CSR not found: $CSR_FILE - run generate-intermediate-csr.sh first." >&2
  exit 1
fi

CERT_FILE="$OUT_DIR/intermediate-ca.crt"
CHAIN_FILE="$OUT_DIR/chain.pem"
EXT_FILE="$(mktemp)"
trap 'rm -f "$EXT_FILE"' EXIT

cat > "$EXT_FILE" <<EOF
# pathlen:1 - this intermediate must still be able to issue a downstream CA
# cert below it (istio-csr's Issuer cert, or SPIRE Server's own CA cert via
# the disk UpstreamAuthority plugin), which in turn signs leaf certs.
# pathlen:0 would make that impossible.
basicConstraints=critical,CA:TRUE,pathlen:1
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

openssl x509 -req \
  -in "$CSR_FILE" \
  -CA "$ROOT_CERT" \
  -CAkey "$ROOT_KEY" \
  -CAcreateserial \
  -CAserial "$OUT_DIR/root-ca.srl" \
  -days "$DAYS" \
  -sha256 \
  -extfile "$EXT_FILE" \
  -out "$CERT_FILE"

cat "$CERT_FILE" "$ROOT_CERT" > "$CHAIN_FILE"

echo "Signed the intermediate CA cert:"
echo "  cert:  $CERT_FILE"
echo "  chain: $CHAIN_FILE  (intermediate + root)"
openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates
