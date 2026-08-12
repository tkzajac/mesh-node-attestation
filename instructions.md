# mesh-node-attestation

## What this project is

A comparison and demo repo for two different ways of establishing trusted
identity for nodes/workloads joining a mesh:

1. **Istio's CSR flow**: ztunnel (Istio ambient's per-node proxy, the only
   mode this repo targets, no sidecars anywhere here) generates a CSR,
   authenticates via a Kubernetes ServiceAccount token, and gets a cert
   back from a CA. Here that CA is cert-manager's `istio-csr` agent,
   backed by a cert-manager `CA` Issuer.
2. **SPIRE's node attestation model**: a `gcp_iit` Node Attestor proves
   the node's identity to SPIRE Server using GCE instance-identity
   evidence, the node gets a Node SVID, and a Workload Attestor then hands
   out SVIDs to things running on that attested node.

**Important terminology point, don't gloss over it**: Istio has no real
"node attestation" concept. Its CSR flow authenticates *workloads* via
their K8s ServiceAccount token, not nodes. SPIRE has a genuine two-tier
model (node, then workload). `docs/COMPARISON.md` calls this out
explicitly; keep that distinction intact in anything written here rather
than treating the two mechanisms as apples-to-apples equivalents.

## The simulated authority

This repo defaults to its own **emulated offline root CA scripts**
(`authority/generate-root.sh`, `generate-intermediate-csr.sh`,
`sign-intermediate.sh`, plain openssl) rather than a real cloud CA, and
deliberately does **not** include any GCP CAS Terraform (CA pools, KMS
BYOK import, cross-project IAM). That solves a different problem, a real
production PKI hierarchy, and has nothing to do with
explaining/demonstrating attestation mechanics here.

Both paths' Issuer/UpstreamAuthority layer is swappable: SPIRE's
`UpstreamAuthority "disk"` plugin (pointed at the emulated intermediate)
could be swapped for `gcp_cas` (pointed at a real GCP CAS pool) with no
other change to the attestation flow, and istio-csr's cert-manager `CA`
Issuer (pointed at the emulated intermediate as a Secret) could equally be
swapped for `cert-manager-google-cas-issuer` (pointed at a real CAS pool)
with no change to istio-csr itself. See
[../istio-csr/cert-manager/issuer-cas-example.yaml](../istio-csr/cert-manager/issuer-cas-example.yaml)
for the shape of that swap. The default in this repo stays the emulated
authority; treat the CAS option as documented, not implemented, unless
told otherwise.

Each path (`istio-csr/`, `spire/`) gets its own **fully independent**
root + intermediate under `authority/istio/` and `authority/spire/`, not
one shared trust root. See `docs/COMPARISON.md` for why.

The SPIRE path's node attestor is `gcp_iit`, which means it **requires a
real GCE/GKE instance metadata server** to produce genuine attestation
evidence. It cannot be exercised on local kind/minikube. The Istio-CSR
path has no such constraint. See `spire/README.md`.

## Current phase

Docs + runnable demo manifests, not a design-only repo. `docs/COMPARISON.md`
is the source of truth for the conceptual comparison. If anything else
here disagrees with it, `COMPARISON.md` wins and the other doc needs
updating.

## Working conventions

- No secrets, real GCP project IDs, or credentials committed. GCP
  project/region are left as placeholders (`<GCP_PROJECT_ID>`, `<ZONE>`)
  throughout `spire/README.md` and related manifests. Never fill these in
  with a real project ID in anything committed to this repo, which is
  public.
- Private key material (`*.key`, `*.pem`, `*.srl`, `*.csr`) under
  `authority/` is gitignored. Regenerate it locally via the
  `authority/*.sh` scripts rather than expecting it to be present.
- Keep `istio-csr/` and `spire/` manifests independently applyable. No
  cross-references between the two demo paths beyond both being able to
  target the same cluster if run side by side.
