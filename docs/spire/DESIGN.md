# SPIRE node attestation — design detail

Companion to [../COMPARISON.md](../COMPARISON.md) — read that first for the
high-level diagram and how this path compares to Istio's CSR flow. This
doc is the deep dive on this path specifically. Demo manifests live in
[../../spire/](../../spire/).

## Components

- **SPIRE Server** — the trust-domain-wide authority. Holds its own CA
  cert (obtained from the configured UpstreamAuthority at startup) and
  issues SVIDs. A production multi-region deployment would typically run
  one per region/cluster; this repo demos a single instance.
- **SPIRE Agent** — node-local daemon. Performs Node Attestation once at
  startup (and on cert renewal), then serves the **Workload API** (a local
  Unix domain socket) to anything running on that node.
- **Node Attestor plugin (`gcp_iit`)** — server- and agent-side plugin
  pair. Agent side fetches a signed instance identity document from the
  GCE metadata server; server side verifies it against Google's public
  keys and the GCE API. See [../COMPARISON.md](../COMPARISON.md)'s "Real
  code" section under Path 2 for the actual Go source (both sides,
  trimmed, with links to the full files in `spiffe/spire`).
- **Workload Attestor plugin (`k8s`)** — server- and agent-side; agent
  side inspects the calling process's cgroup to resolve it to a K8s pod,
  server side matches that against registered entries' selectors.

## Two-tier attestation, in detail

**Tier 1 — Node Attestation (once per node, roughly):**

1. SPIRE Agent starts on a node, has no identity yet.
2. It calls the local GCE metadata server for a **signed instance
   identity document** — a JWT-like structure Google signs, containing the
   instance ID, project, zone, and instance creation timestamp. This is
   not something a process on the node can forge; only the metadata server
   (backed by the hypervisor) can produce it for that specific instance.
3. Agent sends this document to SPIRE Server as Node Attestation evidence.
4. Server verifies the signature against Google's public keys, checks the
   instance is real (calls the GCE API), and checks it hasn't already been
   used to attest a *different* agent identity (replay protection via the
   instance ID).
5. If it all checks out, Server issues a **Node SVID** — an X.509 cert
   whose SPIFFE ID encodes the node's identity
   (`spiffe://<trust-domain>/spire/agent/gcp_iit/<project>/<instance-id>`).

**Tier 2 — Workload Attestation (per workload, on every Workload API
call):**

1. A workload (e.g. ztunnel, or a directly-integrated process) connects to
   the Agent's local Workload API socket.
2. Agent's Workload Attestor plugin resolves the calling process's PID to
   its cgroup, and from there to K8s pod/namespace/ServiceAccount
   metadata.
3. Agent checks that metadata against entries **registered on SPIRE
   Server** ahead of time (selectors like `k8s:ns:default`,
   `k8s:sa:my-workload`) — an entry must exist and match, or the request is
   rejected.
4. If matched, Agent requests (or serves from cache) a **Workload SVID**
   for that entry's SPIFFE ID, signed under the Node SVID's authority —
   i.e. this workload's identity is only as trustworthy as the node
   attestation that already happened in Tier 1.

The key structural point: **Tier 2 cannot happen without Tier 1 already
having succeeded.** An Agent with no valid Node SVID can't serve the
Workload API at all.

## Authority wiring in this repo

SPIRE Server's config (`spire/server/`, see
[../../spire/README.md](../../spire/README.md)) sets:

```hcl
UpstreamAuthority "disk" {
    plugin_data {
        cert_file_path = "/run/spire/authority/intermediate-ca.crt"
        key_file_path  = "/run/spire/authority/intermediate.key"
    }
}
```

pointed at `authority/spire/intermediate-ca.crt` + `.key` mounted into the
Server pod — **not** the `gcp_cas` UpstreamAuthority plugin a production
deployment would more likely use to talk to a real GCP CAS pool. At
startup, SPIRE Server
requests its own CA cert from this intermediate, making the full chain
`authority/spire/root-ca.crt -> intermediate-ca.crt -> SPIRE Server's own
CA cert -> Node/Workload SVIDs`.

`NodeAttestor "gcp_iit"` is configured on both Server and Agent sides —
see `spire/server/` and `spire/agent/` for the exact plugin config
(`projectid_allow_list` restricting which GCP project's instances can
attest).

## Why this needs a real GKE cluster

`gcp_iit`'s agent-side plugin calls
`http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity`
— that endpoint only exists on real GCE (including GKE node) VMs. There is
no way to fake this on local kind/minikube without replacing the node
attestor entirely (e.g. with `join_token` or `k8s_psat`), which would stop
demonstrating the thing this path exists to show. See
[../../spire/README.md](../../spire/README.md) for the GKE prerequisite
and placeholder project/region variables.

## Proving the k8s WorkloadAttestor handles your cgroup driver

Tier 2 (Workload Attestation) works by the Agent reading the calling
process's `/proc/<pid>/cgroup` and extracting a container ID from it, which
it then correlates to a pod via the K8s API. **The exact cgroup path
format depends on the node's cgroup driver**, and GKE nodes commonly run
the **systemd** driver, not `cgroupfs`:

- `cgroupfs` driver: `/kubepods/burstable/pod<uid>/<container-id>`
- `systemd` driver: `/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod<uid_with_underscores>.slice/cri-containerd-<container-id>.scope`

If the Agent can't parse the format your nodes actually produce, Workload
Attestation fails silently from the workload's point of view (it just
never gets an SVID) — a real, previously-reported failure mode on
systemd-driver GKE nodes. Current SPIRE versions try multiple container-ID
finders automatically (both formats above), but "automatically handled"
isn't the same as "verified for your nodes." To actually prove it:

1. Confirm which driver your nodes use — either check the node's kubelet
   config (`cgroupDriver` field, exposed via `kubectl get --raw
   /api/v1/nodes/<node>/proxy/configz` or by shelling into a node) or just
   read `/proc/1/cgroup` from a debug pod on that node and compare against
   the two formats above.
2. Set `verbose_container_locator_logs = true` on the Agent's `k8s`
   WorkloadAttestor (already set in
   [../../spire/agent/configmap.yaml](../../spire/agent/configmap.yaml)) —
   this logs, per Workload API call, every cgroup entry examined and
   **which finder matched** (or that none did).
3. Trigger a real Workload API fetch (`spire/README.md` step 5) and tail
   the Agent's logs for that pod's request — you should see the matching
   finder named explicitly (e.g. `cri-containerd` via the systemd-style
   regex), not just a generic "attestation succeeded."
4. As a negative-test control, fetch from a pod whose ServiceAccount has
   **no** matching registration entry, and confirm the Agent logs a
   selector mismatch / empty SVID response rather than silently returning
   something — this proves the attestor is actually gating on the
   extracted identity, not just always succeeding.

See [../../spire/README.md](../../spire/README.md) step 6 for the runnable
version of this.

## Known gaps / not yet verified

- Exact `projectid_allow_list` / zone restrictions for the demo — left as
  a placeholder pending a real target project.
- PSC or other network path from Agent to Server — a production
  deployment might use Private Service Connect for this, for tighter
  network isolation; this repo's demo assumes Agent and Server can reach
  each other directly (e.g. same cluster's Service), and doesn't attempt
  to replicate PSC.
