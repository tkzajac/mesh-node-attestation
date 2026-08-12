#!/usr/bin/env bash
# Generates the intermediate CA's key + CSR (EC P-256), to be signed by
# generate-root.sh's root via sign-intermediate.sh. This is the real flow
# for this repo (not a dry run toward a later real CSR) since neither path
# here uses a real cloud CA - see docs/COMPARISON.md.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <out-dir> <subject-cn>" >&2
  echo "  e.g.: $0 authority/istio 'istio-csr Test Intermediate CA (EMULATED)'" >&2
  exit 1
fi

OUT_DIR="$1"
CN="$2"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

KEY_FILE="$OUT_DIR/intermediate.key"
CSR_FILE="$OUT_DIR/intermediate.csr"
SUBJECT="/CN=${CN}/O=mesh-node-attestation-test/C=US"

if [[ -f "$KEY_FILE" || -f "$CSR_FILE" ]]; then
  echo "Refusing to overwrite existing intermediate CSR material in $OUT_DIR." >&2
  exit 1
fi

openssl ecparam -name prime256v1 -genkey -noout -out "$KEY_FILE"
chmod 600 "$KEY_FILE"

openssl req -new \
  -key "$KEY_FILE" \
  -subj "$SUBJECT" \
  -out "$CSR_FILE"

echo "Intermediate key + CSR generated:"
echo "  key: $KEY_FILE  (TEST ONLY - never commit)"
echo "  csr: $CSR_FILE"
