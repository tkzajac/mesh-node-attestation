#!/usr/bin/env bash
# Example registration entries - run against a live spire-server, see
# ../README.md step 5.
#
# gcp_iit's Node SVIDs are per-instance (spiffe://.../spire/agent/gcp_iit/
# <project>/<instance-id>) - a workload entry can't wildcard-parent to
# "any node" the way k8s_psat setups often do, because there's no wildcard
# support in -parentID. Instead, register a NODE ALIAS: one entry that
# groups every node matching a gcp_iit selector (e.g. "same project") under
# one stable SPIFFE ID, then parent workload entries to the alias instead
# of any single instance. This is the standard pattern for cloud IIT node
# attestors - see SPIRE's docs on "Node Aliases".
set -euo pipefail

SPIRE_SERVER_POD="$(kubectl -n spire get pod -l app=spire-server -o jsonpath='{.items[0].metadata.name}')"
kubectl_exec() { kubectl -n spire exec "$SPIRE_SERVER_POD" -- "$@"; }

# 1. Node alias: any node that attested via gcp_iit in <GCP_PROJECT_ID>.
kubectl_exec /opt/spire/bin/spire-server entry create \
  -node \
  -spiffeID "spiffe://mesh-node-attestation.test/node-alias/gcp-nodes" \
  -selector "gcp_iit:project-id:<GCP_PROJECT_ID>"

# 2. Workload entry: any pod in namespace "default" running under
# ServiceAccount "demo", parented to the node alias above (not to a
# specific instance).
kubectl_exec /opt/spire/bin/spire-server entry create \
  -spiffeID "spiffe://mesh-node-attestation.test/ns/default/sa/demo" \
  -parentID "spiffe://mesh-node-attestation.test/node-alias/gcp-nodes" \
  -selector "k8s:ns:default" \
  -selector "k8s:sa:demo"

echo "Registered. Verify with:"
echo "  kubectl -n spire exec $SPIRE_SERVER_POD -- /opt/spire/bin/spire-server entry show"
