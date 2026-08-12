# Istio CSR flow — design detail

Companion to [../COMPARISON.md](../COMPARISON.md) — read that first for the
high-level diagram and how this path compares to SPIRE's. This doc is the
deep dive on this path specifically. Demo manifests live in
[../../istio-csr/](../../istio-csr/).

## Components

This repo targets **ambient mode exclusively** — see
[../../istio-csr/README.md](../../istio-csr/README.md) for the Helm-based
install (`base`/`istiod`/`cni`/`ztunnel` charts, ambient profile).

- **ztunnel** — one per node, not one per workload, installed via the
  `ztunnel` Helm chart. Proxies mTLS for every ambient-enrolled workload
  on its node and requests/holds certs on their behalf. The private key
  never leaves the component that generated it.
- **istiod** — normally has a built-in CA. Here it's configured to
  delegate CA operations to `istio-csr` instead (`global.caAddress` in
  `istio-csr/istio/istiod-values.yaml`, `ENABLE_CA_SERVER: "false"`).
- **istio-csr** — a cert-manager-integrated CA agent (project:
  `cert-manager/istio-csr`). Validates the requesting workload's K8s SA
  token on incoming CSR requests, then creates a cert-manager
  `CertificateRequest` against a configured Issuer.
- **cert-manager** — general-purpose K8s cert lifecycle controller. Its
  `CA` Issuer type just needs a cert+key pair in a Secret; it doesn't care
  where that pair came from.

## Authentication step, in detail

ztunnel doesn't read each workload's mounted SA token directly — it's a
**separate per-node process**, not colocated inside each workload's pod
filesystem. Instead it authenticates to `istio-csr` using **its own**
ServiceAccount identity, then requests to **impersonate** the target
workload's SPIFFE identity. `istio-csr` only honors that if:

1. ztunnel's own ServiceAccount is on an explicit allowlist
   (`--ca-trusted-node-accounts` / Helm's
   `app.server.caTrustedNodeAccounts` — set to `istio-system/ztunnel` in
   [../../istio-csr/istio-csr/values.yaml](../../istio-csr/istio-csr/values.yaml)),
   and
2. a live Kubernetes informer index confirms a pod with the requested
   identity is actually scheduled on ztunnel's own node right now.

This is confirmed directly from `istio-csr`'s own source and its own
README (not inferred) — see
[../COMPARISON.md](../COMPARISON.md)'s "Real code" section under Path 1
for the actual excerpts and links. It's explicitly modeled on Kubernetes'
own [Node
Authorization](https://kubernetes.io/docs/reference/access-authn-authz/node/).

**Still worth being precise about**: this is a live-state check against
the K8s control plane's bookkeeping, not an independent cryptographic
attestation of the node itself — contrast with SPIRE's `gcp_iit`, which
verifies a signature chain rooted outside the cluster entirely (Google's
key, not the K8s API's word). See COMPARISON.md's Path 1 "What's actually
being trusted here" for the full contrast.

The structural comparison point to SPIRE still holds regardless: **this is
still a workload-only trust decision.** There is no separate
cryptographic node-identity check anywhere in this flow.

## Authority wiring in this repo

`istio-csr/cert-manager/` (see [../../istio-csr/README.md](../../istio-csr/README.md))
creates:

1. A K8s Secret holding `authority/istio/intermediate-ca.crt` +
   `authority/istio/intermediate.key`.
2. A cert-manager `Issuer` (or `ClusterIssuer`) of type `ca`, referencing
   that Secret.
3. istio-csr's Helm values pointing at that Issuer.

cert-manager signs every leaf cert directly off the intermediate key —
there's no further subordinate-CA hop the way SPIRE Server itself becomes
a subordinate CA (see [../spire/DESIGN.md](../spire/DESIGN.md)). The chain
returned to ztunnel is `leaf -> intermediate -> root`
(`authority/istio/root-ca.crt`).

## Swapping the Issuer for a real CA later

Nothing about istio-csr's config changes if the Issuer backend changes —
only the Issuer manifest does. Real options:

- `cert-manager-google-cas-issuer` — talks to a real GCP CAS pool. See
  [../../istio-csr/cert-manager/issuer-cas-example.yaml](../../istio-csr/cert-manager/issuer-cas-example.yaml)
  for the shape of this — illustrative only, not wired up or applied by
  this repo's walkthrough, since the default here stays the emulated
  authority per the earlier scoping decision (see top-level `README.md`).
- HashiCorp Vault's PKI secrets engine, via cert-manager's `vault` Issuer
  type.

## Known gaps / not yet verified

- Whether the node-colocation check (see above) degrades gracefully or
  fails closed if istio-csr's Pod informer hasn't finished its initial
  sync yet at startup.
- Certificate rotation behavior under istio-csr specifically (vs istiod's
  built-in CA) — expected to be the same default ~24h leaf lifetime, not
  yet confirmed against a running install.
