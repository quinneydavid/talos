#!/bin/bash
set -e

# Default values
CLUSTER_NAME=${CLUSTER_NAME:-k8s.lan}
CLUSTER_ENDPOINT=${CLUSTER_ENDPOINT:-https://api.k8s.lan:6443}

# Node IPs
CONTROL_PLANES=("192.168.86.211" "192.168.86.212" "192.168.86.213")
WORKERS=("192.168.86.214" "192.168.86.215")
ALL_NODES=("${CONTROL_PLANES[@]}" "${WORKERS[@]}")

# Get talosconfig from matchbox container
echo "Retrieving talosconfig from matchbox container..."
cd talos/docker && docker cp docker_matchbox_1:/var/lib/matchbox/assets/talosconfig ../tmp/talosconfig
cd -

# Export TALOSCONFIG
export TALOSCONFIG=talos/tmp/talosconfig

# Wait for all nodes to be ready
echo "Waiting for all nodes to be ready..."
for node in "${ALL_NODES[@]}"; do
    echo "Waiting for node ${node}..."
    talosctl --nodes ${node} health --wait-timeout 10m
done

# Bootstrap the first control plane
echo "Bootstrapping the first control plane node..."
talosctl --nodes ${CONTROL_PLANES[0]} bootstrap

# Wait for Kubernetes to be ready on first control plane
echo "Waiting for Kubernetes to be ready on first control plane..."
talosctl --nodes ${CONTROL_PLANES[0]} health --wait-timeout 10m

# Get kubeconfig
echo "Retrieving kubeconfig..."
talosctl --nodes ${CONTROL_PLANES[0]} kubeconfig /tmp/kubeconfig
export KUBECONFIG=/tmp/kubeconfig

# Wait for all nodes to be ready in Kubernetes
echo "Waiting for all nodes to be ready in Kubernetes..."
kubectl wait --for=condition=ready node --all --timeout=10m

echo "Cluster creation complete!"

# Bootstrap Flux if requested
if [ "$1" = "--with-flux" ]; then
    echo "Bootstrapping Flux..."
    /scripts/bootstrap-flux.sh
fi
