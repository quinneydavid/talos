#!/bin/bash

# Script to generate Talos configurations using base configs as patches
# The generated configs with secrets will only be stored on the matchbox server

set -e

# Directory setup
MATCHBOX_ASSETS="/var/lib/matchbox/assets"
MATCHBOX_GROUPS="/var/lib/matchbox/groups"
mkdir -p "$MATCHBOX_ASSETS"

# Install jq if not present
apk add --no-cache jq

# Read base configurations
CONTROLPLANE_CONFIG=$(cat /configs/controlplane.yaml)
WORKER_CONFIG=$(cat /configs/worker.yaml)

# Generate control plane configs
for node in cp1 cp2 cp3; do
    echo "Generating config for ${node}..."
    
    # Read node metadata from group file
    if [ ! -f "${MATCHBOX_GROUPS}/${node}.json" ]; then
        echo "Error: Group file for ${node} not found"
        continue
    fi
    
    # Extract metadata from group file
    NODE_IP=$(jq -r '.metadata.ip' "${MATCHBOX_GROUPS}/${node}.json")
    STORAGE_IP=$(jq -r '.metadata.storage_ip' "${MATCHBOX_GROUPS}/${node}.json")
    GATEWAY=$(jq -r '.metadata.gateway' "${MATCHBOX_GROUPS}/${node}.json")
    HOSTNAME=$(jq -r '.metadata.hostname' "${MATCHBOX_GROUPS}/${node}.json")
    
    # Node-specific network configuration
    NODE_PATCH="{\"machine\":{\"network\":{\"hostname\":\"${HOSTNAME}\",\"interfaces\":[{\"interface\":\"eth0\",\"addresses\":[\"${NODE_IP}/24\"],\"routes\":[{\"network\":\"0.0.0.0/0\",\"gateway\":\"${GATEWAY}\"}]},{\"interface\":\"eth1\",\"addresses\":[\"${STORAGE_IP}/24\"]}]}}}"
    
    # Generate config using base controlplane config as patch
    talosctl gen config \
        --with-secrets \
        --with-docs=false \
        --config-patch "${CONTROLPLANE_CONFIG}" \
        --config-patch "${NODE_PATCH}" \
        talos-k8s-metal-tutorial https://192.168.86.241:6443
    
    mv controlplane.yaml "${MATCHBOX_ASSETS}/controlplane-${HOSTNAME}.yaml"
done

# Generate worker configs
for node in worker1 worker2; do
    echo "Generating config for ${node}..."
    
    # Read node metadata from group file
    if [ ! -f "${MATCHBOX_GROUPS}/${node}.json" ]; then
        echo "Error: Group file for ${node} not found"
        continue
    fi
    
    # Extract metadata from group file
    NODE_IP=$(jq -r '.metadata.ip' "${MATCHBOX_GROUPS}/${node}.json")
    STORAGE_IP=$(jq -r '.metadata.storage_ip' "${MATCHBOX_GROUPS}/${node}.json")
    GATEWAY=$(jq -r '.metadata.gateway' "${MATCHBOX_GROUPS}/${node}.json")
    HOSTNAME=$(jq -r '.metadata.hostname' "${MATCHBOX_GROUPS}/${node}.json")
    
    # Node-specific network configuration
    NODE_PATCH="{\"machine\":{\"network\":{\"hostname\":\"${HOSTNAME}\",\"interfaces\":[{\"interface\":\"eth0\",\"addresses\":[\"${NODE_IP}/24\"],\"routes\":[{\"network\":\"0.0.0.0/0\",\"gateway\":\"${GATEWAY}\"}]},{\"interface\":\"eth1\",\"addresses\":[\"${STORAGE_IP}/24\"]}]}}}"
    
    # Generate config using base worker config as patch
    talosctl gen config \
        --with-secrets \
        --with-docs=false \
        --config-patch "${WORKER_CONFIG}" \
        --config-patch "${NODE_PATCH}" \
        talos-k8s-metal-tutorial https://192.168.86.241:6443
    
    mv worker.yaml "${MATCHBOX_ASSETS}/worker-${HOSTNAME}.yaml"
done

# Clean up talosconfig since we don't need it
rm -f talosconfig

echo "Configuration generation complete! Configs are stored in $MATCHBOX_ASSETS"
echo "Note: The generated configs contain secrets and should only be stored on the matchbox server."
