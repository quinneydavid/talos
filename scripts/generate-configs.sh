#!/bin/bash

# Script to generate Talos configurations using base configs as patches
# The generated configs with secrets will only be stored on the matchbox server

set -e

# Directory setup
MATCHBOX_ASSETS="../matchbox/assets"
mkdir -p "$MATCHBOX_ASSETS"

# Read base configurations
CONTROLPLANE_CONFIG=$(cat ../configs/controlplane.yaml)
WORKER_CONFIG=$(cat ../configs/worker.yaml)

# Generate control plane configs
for i in {1..3}; do
    NODE_IP="192.168.86.21${i}"
    STORAGE_IP="192.168.87.21${i}"
    HOSTNAME="cp${i}"
    
    # Node-specific network configuration
    NODE_PATCH="{\"machine\":{\"network\":{\"hostname\":\"${HOSTNAME}\",\"interfaces\":[{\"interface\":\"eth0\",\"addresses\":[\"${NODE_IP}/24\"],\"routes\":[{\"network\":\"0.0.0.0/0\",\"gateway\":\"192.168.86.1\"}]},{\"interface\":\"eth1\",\"addresses\":[\"${STORAGE_IP}/24\"]}]}}}"
    
    echo "Generating config for ${HOSTNAME}..."
    
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
for i in {1..2}; do
    NODE_IP="192.168.86.22${i}"
    STORAGE_IP="192.168.87.22${i}"
    HOSTNAME="worker${i}"
    
    # Node-specific network configuration
    NODE_PATCH="{\"machine\":{\"network\":{\"hostname\":\"${HOSTNAME}\",\"interfaces\":[{\"interface\":\"eth0\",\"addresses\":[\"${NODE_IP}/24\"],\"routes\":[{\"network\":\"0.0.0.0/0\",\"gateway\":\"192.168.86.1\"}]},{\"interface\":\"eth1\",\"addresses\":[\"${STORAGE_IP}/24\"]}]}}}"
    
    echo "Generating config for ${HOSTNAME}..."
    
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
