# istio-csr demo — Istio ambient's CSR flow with a simulated authority

Design detail: [../docs/istio-csr/DESIGN.md](../docs/istio-csr/DESIGN.md).
High-level comparison: [../docs/COMPARISON.md](../docs/COMPARISON.md).

Targets **ambient mode exclusively** (ztunnel). Installed via Istio's own
Helm charts, not `istioctl`/`IstioOperator` — see
[../docs/istio-csr/DESIGN.md](../docs/istio-csr/DESIGN.md) for why. Runs
on **any** cluster including local kind — upstream/OSS ztunnel gets its
certs from istio-csr directly, no special distribution needed for *this*
path. (The separate ztunnel↔SPIRE DelegatedIdentity integration — not
part of this repo's SPIRE path either, see
[../spire/README.md](../spire/README.md) — is the one that currently
requires a non-upstream ztunnel distribution.)

## Prerequisites

- A running K8s cluster (`kind create cluster` is enough).
- `helm`, `istioctl`, `kubectl`, `openssl` on your path.
- cert-manager installed:
  ```sh
  helm repo add jetstack https://charts.jetstack.io && helm repo update
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true
  ```

> Steps 1-2 below wire istio-csr to the **emulated** authority. To point at
> a real GCP CAS pool instead, skip both and see
> [cert-manager/issuer-cas-example.yaml](cert-manager/issuer-cas-example.yaml)
> — illustrative only, requires the separate
> `cert-manager-google-cas-issuer` controller, not applied by this
> walkthrough.

## 1. Generate the emulated authority

```sh
./authority/generate-root.sh authority/istio "istio-csr Test Root CA (EMULATED)"
./authority/generate-intermediate-csr.sh authority/istio "istio-csr Test Intermediate CA (EMULATED)"
./authority/sign-intermediate.sh authority/istio
```

## 2. Load the intermediate into cert-manager, apply the Issuer

```sh
kubectl create secret tls istio-csr-ca \
  --cert=authority/istio/intermediate-ca.crt \
  --key=authority/istio/intermediate.key \
  -n cert-manager

kubectl apply -f istio-csr/cert-manager/issuer.yaml

# Also make the root available for istiod / workloads to validate against:
kubectl create configmap istio-csr-ca-root-cert \
  --from-file=ca.crt=authority/istio/root-ca.crt \
  -n cert-manager
```

## 3. Install istio-csr

`istio-csr/istio-csr/values.yaml` sets
`app.server.caTrustedNodeAccounts: "istio-system/ztunnel"` — **required**
for ambient mode. Without it, istio-csr rejects every cert request
ztunnel makes on behalf of the workloads it's proxying for (ztunnel isn't
colocated in each workload's pod, so it authenticates as itself and asks
to impersonate the workload's identity — istio-csr only allows that for
ServiceAccounts on this list). See
[../docs/COMPARISON.md](../docs/COMPARISON.md)'s "Real code" section under
Path 1 for exactly what this triggers.

```sh
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm upgrade -i -n cert-manager istio-csr jetstack/cert-manager-istio-csr \
  -f istio-csr/istio-csr/values.yaml
kubectl -n cert-manager rollout status deploy/cert-manager-istio-csr
```

## 4. Install Istio ambient, delegating its CA to istio-csr

Four Helm installs — `base` (CRDs), `istiod` (control plane, ambient
profile, CA delegated to istio-csr), `cni` (node-level pod redirection),
`ztunnel` (the per-node mTLS proxy). Check `helm show values istio/istiod`
against the chart version
you pull if any key in `istiod-values.yaml` doesn't apply — exact value
paths shift across Istio releases.

```sh
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

helm upgrade -i istio-base istio/base -n istio-system --create-namespace --wait

helm upgrade -i istiod istio/istiod -n istio-system \
  --set profile=ambient \
  -f istio-csr/istio/istiod-values.yaml \
  --wait

helm upgrade -i istio-cni istio/cni -n istio-system --set profile=ambient --wait

helm upgrade -i ztunnel istio/ztunnel -n istio-system --wait
```

## 5. Deploy a sample workload and inspect its issued cert

Ambient enrolls a *namespace* by label. Use `istioctl ztunnel-config` to
inspect the certs ztunnel is holding (check `istioctl ztunnel-config
--help` for your installed istioctl version — the ambient CLI surface has
moved around across Istio releases):

```sh
kubectl label namespace default istio.io/dataplane-mode=ambient
kubectl run demo --image=nginx --restart=Never
kubectl wait --for=condition=ready pod/demo

ZTUNNEL_POD="$(kubectl -n istio-system get pod -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')"

# Pull the workload's cert out of ztunnel and check its chain:
istioctl ztunnel-config certificates "$ZTUNNEL_POD" -n istio-system -o json \
  | jq -r '.[] | select(.identity | contains("default")) | .certChain' \
  > /tmp/demo-workload-cert.pem

openssl verify \
  -CAfile authority/istio/root-ca.crt \
  -untrusted authority/istio/intermediate-ca.crt \
  /tmp/demo-workload-cert.pem
```

A successful `verify` output confirms the workload's cert chains all the
way back to `authority/istio/root-ca.crt` through istio-csr and our
emulated intermediate — the whole point of this demo. No non-upstream
component was needed to get here.

## Teardown

```sh
helm uninstall -n istio-system ztunnel
helm uninstall -n istio-system istio-cni
helm uninstall -n istio-system istiod
helm uninstall -n istio-system istio-base
helm uninstall -n cert-manager istio-csr
helm uninstall -n cert-manager cert-manager
kubectl delete configmap istio-csr-ca-root-cert -n cert-manager
kubectl delete secret istio-csr-ca -n cert-manager
```
