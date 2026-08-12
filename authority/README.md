# authority/ — emulated CAs for both paths

Plain-openssl scripts that emulate an offline root CA signing one
intermediate. **Not a real org root process** — a real offline root
ceremony is normally owned/operated by a dedicated PKI/crypto team,
outside any single service's repo. Here, this emulation isn't a stand-in
for a later real step at all — it's the whole authority for both demo
paths in this repo.

Each path gets its **own independent** root + intermediate — there is no
shared trust point between `istio/` and `spire/`. See
[../docs/COMPARISON.md](../docs/COMPARISON.md) for why.

## Layout (generated, gitignored key material)

```
authority/
  generate-root.sh              # creates a root CA in <out-dir>
  generate-intermediate-csr.sh  # creates an intermediate key + CSR in <out-dir>
  sign-intermediate.sh          # signs <out-dir>/intermediate.csr with <out-dir>'s root
  istio/
    root-ca.key / root-ca.crt           # (key gitignored) istio-csr path's root
    intermediate.key / intermediate.csr # (gitignored) istio-csr path's intermediate CSR
    intermediate-ca.crt                 # signed intermediate cert
    chain.pem                           # (gitignored) intermediate + root
  spire/
    root-ca.key / root-ca.crt           # (key gitignored) SPIRE path's root
    intermediate.key / intermediate.csr # (gitignored) SPIRE path's intermediate CSR
    intermediate-ca.crt                 # signed intermediate cert
    chain.pem                           # (gitignored) intermediate + root
```

## Usage

Run the same three scripts once per path:

```sh
# istio-csr path
./authority/generate-root.sh authority/istio "istio-csr Test Root CA (EMULATED)"
./authority/generate-intermediate-csr.sh authority/istio "istio-csr Test Intermediate CA (EMULATED)"
./authority/sign-intermediate.sh authority/istio

# SPIRE path
./authority/generate-root.sh authority/spire "SPIRE Test Root CA (EMULATED)"
./authority/generate-intermediate-csr.sh authority/spire "SPIRE Test Intermediate CA (EMULATED)"
./authority/sign-intermediate.sh authority/spire
```

Verify either chain independently:

```sh
openssl verify -CAfile authority/istio/root-ca.crt authority/istio/intermediate-ca.crt
openssl verify -CAfile authority/spire/root-ca.crt authority/spire/intermediate-ca.crt
```

Each script refuses to overwrite existing material — remove the relevant
files manually first if you want to regenerate a chain.

## What downstream config expects

- `istio-csr/cert-manager/` builds a cert-manager `CA` Issuer from
  `authority/istio/intermediate-ca.crt` + `authority/istio/intermediate.key`
  (packaged as a K8s Secret) — istio-csr issues workload certs off that
  Issuer directly. No further hop.
- `spire/server/` configures SPIRE Server's `UpstreamAuthority "disk"`
  plugin to point at `authority/spire/chain.pem` +
  `authority/spire/intermediate.key` — SPIRE Server requests its own CA
  cert from that intermediate at startup, then signs Node/Workload SVIDs
  itself.

## Why no GCP CAS / KMS BYOK tooling here

A real GCP CAS deployment needs additional steps this repo deliberately
skips: generating key material for GCP Cloud KMS BYOK import, then
activating a GCP CAS CA resource against it. Neither path in this repo
uses GCP CAS, so none of that tooling is needed here — see
[../docs/COMPARISON.md](../docs/COMPARISON.md) for why, and
[../istio-csr/cert-manager/issuer-cas-example.yaml](../istio-csr/cert-manager/issuer-cas-example.yaml)
for what pointing at a real CAS pool later would look like.
