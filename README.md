# mesh-node-attestation

A comparison and demo of two ways to establish trusted identity for
nodes/workloads joining a mesh:

1. **Istio's CSR flow**, via cert-manager's `istio-csr` — ztunnel (Istio
   ambient's per-node proxy) gets a cert by presenting a CSR + K8s
   ServiceAccount token.
2. **SPIRE's node attestation model** — a `gcp_iit` Node Attestor proves
   the node's identity from GCE instance metadata, then a Workload
   Attestor issues per-workload SVIDs on top of that.

If you're an AI assistant working in this repo, read
[instructions.md](instructions.md) first. This README is the human-facing
entry point.

**Read [docs/COMPARISON.md](docs/COMPARISON.md) first** — it's the source
of truth: trust-chain diagrams for both paths, sequence diagrams, a
terminology note (Istio doesn't actually do node attestation — see why
that distinction matters), and a side-by-side comparison table.

## Architecture at a glance

Both paths use their own **fully independent simulated authority** (plain
openssl root + intermediate — see [authority/README.md](authority/README.md)) —
neither talks to a real GCP CAS. See
[docs/COMPARISON.md](docs/COMPARISON.md) for why they're kept independent
rather than sharing one trust root.

```
authority/istio/  (root -> intermediate)          authority/spire/  (root -> intermediate)
        |                                                  |
   cert-manager CA Issuer                          SPIRE Server (UpstreamAuthority: disk)
        |                                                  |
   istio-csr  <-- CSR + K8s SA token -- ztunnel       SPIRE Agent <-- GCE instance identity doc (gcp_iit)
        |                                                  |
   leaf cert --> workload                          Node SVID --> Workload Attestor --> Workload SVID --> workload
```

## Documentation map

| Doc | What it's for |
|---|---|
| [instructions.md](instructions.md) | AI-assistant context and working conventions. |
| [docs/COMPARISON.md](docs/COMPARISON.md) | **Source of truth.** Trust chains, sequence diagrams, terminology, comparison table, open questions. |
| [docs/istio-csr/DESIGN.md](docs/istio-csr/DESIGN.md) | Deep dive on the Istio CSR flow. |
| [docs/spire/DESIGN.md](docs/spire/DESIGN.md) | Deep dive on SPIRE's node/workload attestation. |
| [authority/README.md](authority/README.md) | The emulated-CA scripts shared by both paths. |
| [istio-csr/README.md](istio-csr/README.md) | Runnable walkthrough — works on local kind. |
| [spire/README.md](spire/README.md) | Runnable walkthrough — **needs a real GKE cluster** (`gcp_iit` requires real GCE metadata). |

## Quickstart

```sh
# Generate both paths' emulated authorities
./authority/generate-root.sh authority/istio "istio-csr Test Root CA (EMULATED)"
./authority/generate-intermediate-csr.sh authority/istio "istio-csr Test Intermediate CA (EMULATED)"
./authority/sign-intermediate.sh authority/istio

./authority/generate-root.sh authority/spire "SPIRE Test Root CA (EMULATED)"
./authority/generate-intermediate-csr.sh authority/spire "SPIRE Test Intermediate CA (EMULATED)"
./authority/sign-intermediate.sh authority/spire
```

Then follow [istio-csr/README.md](istio-csr/README.md) and/or
[spire/README.md](spire/README.md) for the full per-path walkthrough.

## Why a simulated authority instead of a real cloud CA

Both paths use their own openssl-based emulated offline root + intermediate
(`authority/*.sh` — see [authority/README.md](authority/README.md)),
**not** a real cloud CA (e.g. GCP CAS: CA pools, KMS BYOK import,
cross-project IAM). Standing up a real production PKI hierarchy solves a
different problem and isn't needed to demonstrate or compare how these two
systems attest identity — both paths here simulate their own authority
instead. See [docs/COMPARISON.md](docs/COMPARISON.md) for the full
reasoning, and
[istio-csr/cert-manager/issuer-cas-example.yaml](istio-csr/cert-manager/issuer-cas-example.yaml)
for what swapping in a real GCP CAS pool later would look like.

## Working conventions

See [instructions.md](instructions.md) — notably: no secrets or real GCP
project IDs committed (placeholders throughout), private key material
gitignored, and `docs/COMPARISON.md` is authoritative — if anything else
here disagrees with it, `docs/COMPARISON.md` wins and the other doc needs
updating.
