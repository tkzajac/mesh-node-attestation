# SPIRE demo — node attestation with a simulated authority

Design detail: [../docs/spire/DESIGN.md](../docs/spire/DESIGN.md).
High-level comparison: [../docs/COMPARISON.md](../docs/COMPARISON.md).

**This entire demo — node attestation, workload attestation, SVID
issuance — requires no mesh and no ztunnel at all.** Steps 4–6 below prove
the full attestation pipeline using only `spire-server`/`spire-agent`'s
own CLIs. Wiring ztunnel to SPIRE's DelegatedIdentity API for live mTLS is
a separate step, out of scope here — note that as of writing, that
integration isn't available in upstream/OSS ztunnel, only in certain
vendor distributions, so check your distribution's support before relying
on it.

## Prerequisite: a real GKE cluster — not local kind/minikube

The Node Attestor here is `gcp_iit` (see COMPARISON.md for why this repo
didn't use the fully-portable `k8s_psat` instead). Its agent-side plugin
calls the **GCE instance metadata server** for a signed identity document
— that endpoint only exists on real GCE/GKE node VMs, so this demo needs
an actual (even if small/throwaway) GKE cluster. `<GCP_PROJECT_ID>` and
`<ZONE>` below are placeholders — fill in your own test project, never a
real project ID in anything committed to this repo.

```sh
gcloud container clusters create mesh-node-attestation-demo \
  --project=<GCP_PROJECT_ID> --zone=<ZONE> \
  --num-nodes=1 --machine-type=e2-small
gcloud container clusters get-credentials mesh-node-attestation-demo \
  --project=<GCP_PROJECT_ID> --zone=<ZONE>
```

## 1. Generate the emulated authority

```sh
./authority/generate-root.sh authority/spire "SPIRE Test Root CA (EMULATED)"
./authority/generate-intermediate-csr.sh authority/spire "SPIRE Test Intermediate CA (EMULATED)"
./authority/sign-intermediate.sh authority/spire
```

## 2. Namespace, RBAC, and the authority Secrets/ConfigMaps

```sh
kubectl apply -f spire/server/serviceaccount.yaml   # also creates the spire namespace
kubectl apply -f spire/agent/serviceaccount.yaml

kubectl create secret generic spire-server-upstream-ca \
  --from-file=intermediate-ca.crt=authority/spire/intermediate-ca.crt \
  --from-file=intermediate.key=authority/spire/intermediate.key \
  -n spire

kubectl create configmap spire-bundle \
  --from-file=bundle.crt=authority/spire/root-ca.crt \
  -n spire
```

## 3. Deploy SPIRE Server and Agent

```sh
kubectl apply -f spire/server/configmap.yaml
kubectl apply -f spire/server/statefulset.yaml
kubectl apply -f spire/server/service.yaml
kubectl -n spire rollout status statefulset/spire-server

kubectl apply -f spire/agent/configmap.yaml
kubectl apply -f spire/agent/daemonset.yaml
kubectl -n spire rollout status daemonset/spire-agent
```

Fill in `<GCP_PROJECT_ID>` in `spire/server/configmap.yaml`'s
`projectid_allow_list` before applying, or the Node Attestor will reject
every node.

## 4. Confirm node attestation happened

```sh
kubectl -n spire logs -l app=spire-agent --tail=20
# Look for "Node attestation was successful" and the resulting
# spiffe://mesh-node-attestation.test/spire/agent/gcp_iit/... ID.
```

This is the step that has no equivalent in the Istio CSR path — a real
trust decision about the *node*, independent of anything workload-related.

## 5. Register entries, deploy a workload, verify its SVID

```sh
./spire/registration/entries.sh   # fill in <GCP_PROJECT_ID> first

kubectl create serviceaccount demo -n default
kubectl run demo --image=busybox --restart=Never -n default \
  --overrides='{"spec":{"serviceAccountName":"demo"}}' \
  -- sleep infinity

# From inside a debug container sharing the node's Workload API socket:
kubectl debug -n spire -it $(kubectl -n spire get pod -l app=spire-agent -o jsonpath='{.items[0].metadata.name}') \
  --image=ghcr.io/spiffe/spire-agent:1.9.6 -- \
  /opt/spire/bin/spire-agent api fetch x509 -socketPath /run/spire/sockets/agent.sock
```

The returned SVID's chain should verify against
`authority/spire/root-ca.crt`:

```sh
openssl verify \
  -CAfile authority/spire/root-ca.crt \
  -untrusted authority/spire/intermediate-ca.crt \
  /path/to/fetched/svid.pem
```

## 6. Prove the k8s WorkloadAttestor actually handles your node's cgroup driver

GKE nodes commonly run the **systemd** cgroup driver, which produces a
different `/proc/<pid>/cgroup` path format than `cgroupfs` — see
[../docs/spire/DESIGN.md](../docs/spire/DESIGN.md)'s "Proving the k8s
WorkloadAttestor handles your cgroup driver" for why that matters. This
step proves it's actually being parsed correctly on your nodes, not just
assumed.

```sh
# 1. Which driver are your nodes actually using?
kubectl debug node/<node-name> -it --image=busybox -- \
  cat /host/proc/1/cgroup
# systemd-driver format looks like:
#   .../kubepods.slice/kubepods-burstable.slice/.../cri-containerd-<id>.scope
# cgroupfs-driver format looks like:
#   .../kubepods/burstable/pod<uid>/<id>

# 2. verbose_container_locator_logs is already set in
#    spire/agent/configmap.yaml - tail the Agent's logs while step 5's
#    "spire-agent api fetch" runs, and confirm you see the specific
#    container-ID finder that matched (not just "attestation succeeded"):
kubectl -n spire logs -l app=spire-agent -f &
# ...re-run the fetch from step 5 in another shell, then Ctrl-C the tail...

# 3. Negative-test control: fetch from a workload with NO matching
# registration entry, and confirm it's rejected rather than silently
# succeeding.
kubectl create serviceaccount unregistered -n default
kubectl run unregistered-demo --image=busybox --restart=Never -n default \
  --overrides='{"spec":{"serviceAccountName":"unregistered"}}' \
  -- sleep infinity
kubectl debug -n spire -it $(kubectl -n spire get pod -l app=spire-agent -o jsonpath='{.items[0].metadata.name}') \
  --image=ghcr.io/spiffe/spire-agent:1.9.6 -- \
  /opt/spire/bin/spire-agent api fetch x509 -socketPath /run/spire/sockets/agent.sock
# Expect an empty/error response here - proves the attestor is gating on
# the extracted pod identity, not just always returning an SVID.
```

## Teardown

```sh
kubectl delete namespace spire
gcloud container clusters delete mesh-node-attestation-demo \
  --project=<GCP_PROJECT_ID> --zone=<ZONE>
```
