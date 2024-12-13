#!/bin/bash

# Script to generate Talos configurations using talosctl
# This generates configs with secrets that should only be stored on the matchbox server

set -e

# Directory setup
MATCHBOX_ASSETS="/var/lib/matchbox/assets"
MATCHBOX_GROUPS="/var/lib/matchbox/groups"
mkdir -p "$MATCHBOX_ASSETS"

# Ensure jq is available
if ! command -v jq &> /dev/null; then
    echo "jq is required but not installed"
    exit 1
fi

echo "Generating Talos configurations..."

# Create base config files
BASE_CP_FILE=$(mktemp)
cat > "$BASE_CP_FILE" << EOF
machine:
  type: controlplane
  install:
    disk: /dev/sda
EOF

BASE_WORKER_FILE=$(mktemp)
cat > "$BASE_WORKER_FILE" << EOF
machine:
  type: worker
  install:
    disk: /dev/sda
EOF

# Collect all control plane IPs
declare -a CONTROL_PLANE_IPS
for node in cp1 cp2 cp3; do
    if [ -f "${MATCHBOX_GROUPS}/${node}.json" ]; then
        ip=$(jq -r '.metadata.ip' "${MATCHBOX_GROUPS}/${node}.json")
        CONTROL_PLANE_IPS+=("\"$ip\"")
    fi
done

# Join IPs with commas
CERT_SANS=$(IFS=,; echo "[${CONTROL_PLANE_IPS[*]}, \"api.k8s.lan\"]")

# Generate control plane configs
for node in cp1 cp2 cp3; do
    echo "Generating config for ${node}..."
    
    # Read node metadata from group file
    GROUP_FILE="${MATCHBOX_GROUPS}/${node}.json"
    if [ ! -f "$GROUP_FILE" ]; then
        echo "Error: Group file for ${node} not found at ${GROUP_FILE}"
        continue
    fi
    
    echo "Reading metadata from ${GROUP_FILE}"
    # Extract metadata from group file
    NODE_IP=$(jq -r '.metadata.ip' "$GROUP_FILE")
    STORAGE_IP=$(jq -r '.metadata.storage_ip' "$GROUP_FILE")
    GATEWAY=$(jq -r '.metadata.gateway' "$GROUP_FILE")
    HOSTNAME=$(jq -r '.metadata.hostname' "$GROUP_FILE")
    NAMESERVERS=$(jq -r '.metadata.nameservers | join(",")' "$GROUP_FILE")
    
    echo "Extracted metadata for ${HOSTNAME}:"
    echo "  IP: ${NODE_IP}"
    echo "  Storage IP: ${STORAGE_IP}"
    echo "  Gateway: ${GATEWAY}"
    echo "  Nameservers: ${NAMESERVERS}"
    
    # Create a temporary file for the patch
    PATCH_FILE=$(mktemp)
    cat > "$PATCH_FILE" << EOF
{
    "machine": {
        "network": {
            "hostname": "${HOSTNAME}",
            "nameservers": [${NAMESERVERS}],
            "interfaces": [
                {
                    "interface": "eth0",
                    "addresses": ["${NODE_IP}/24"],
                    "routes": [{"network": "0.0.0.0/0", "gateway": "${GATEWAY}"}]
                },
                {
                    "interface": "eth1",
                    "addresses": ["${STORAGE_IP}/24"]
                }
            ]
        },
        "certSANs": ${CERT_SANS}
    }
}
EOF
    
    echo "Generating controlplane config with talosctl..."
    talosctl gen config \
        --output-types controlplane \
        --config-patch "$(cat $BASE_CP_FILE)" \
        --config-patch "$(cat $PATCH_FILE)" \
        --with-docs=false \
        --dns-domain cluster.local \
        k8s.lan \
        https://api.k8s.lan:6443
    
    OUTPUT_FILE="${MATCHBOX_ASSETS}/controlplane-${HOSTNAME}.yaml"
    if [ -f controlplane.yaml ]; then
        echo "Moving controlplane.yaml to ${OUTPUT_FILE}"
        mv controlplane.yaml "${OUTPUT_FILE}"
    else
        echo "Error: controlplane.yaml was not generated"
    fi
    
    rm "$PATCH_FILE"
done

# Generate worker configs
for node in worker1 worker2; do
    echo "Generating config for ${node}..."
    
    # Read node metadata from group file
    GROUP_FILE="${MATCHBOX_GROUPS}/${node}.json"
    if [ ! -f "$GROUP_FILE" ]; then
        echo "Error: Group file for ${node} not found at ${GROUP_FILE}"
        continue
    fi
    
    echo "Reading metadata from ${GROUP_FILE}"
    # Extract metadata from group file
    NODE_IP=$(jq -r '.metadata.ip' "$GROUP_FILE")
    STORAGE_IP=$(jq -r '.metadata.storage_ip' "$GROUP_FILE")
    GATEWAY=$(jq -r '.metadata.gateway' "$GROUP_FILE")
    HOSTNAME=$(jq -r '.metadata.hostname' "$GROUP_FILE")
    NAMESERVERS=$(jq -r '.metadata.nameservers | join(",")' "$GROUP_FILE")
    
    echo "Extracted metadata for ${HOSTNAME}:"
    echo "  IP: ${NODE_IP}"
    echo "  Storage IP: ${STORAGE_IP}"
    echo "  Gateway: ${GATEWAY}"
    echo "  Nameservers: ${NAMESERVERS}"
    
    # Create a temporary file for the patch
    PATCH_FILE=$(mktemp)
    cat > "$PATCH_FILE" << EOF
{
    "machine": {
        "network": {
            "hostname": "${HOSTNAME}",
            "nameservers": [${NAMESERVERS}],
            "interfaces": [
                {
                    "interface": "eth0",
                    "addresses": ["${NODE_IP}/24"],
                    "routes": [{"network": "0.0.0.0/0", "gateway": "${GATEWAY}"}]
                },
                {
                    "interface": "eth1",
                    "addresses": ["${STORAGE_IP}/24"]
                }
            ]
        }
    }
}
EOF
    
    echo "Generating worker config with talosctl..."
    talosctl gen config \
        --output-types worker \
        --config-patch "$(cat $BASE_WORKER_FILE)" \
        --config-patch "$(cat $PATCH_FILE)" \
        --with-docs=false \
        --dns-domain cluster.local \
        k8s.lan \
        https://api.k8s.lan:6443
    
    OUTPUT_FILE="${MATCHBOX_ASSETS}/worker-${HOSTNAME}.yaml"
    if [ -f worker.yaml ]; then
        echo "Moving worker.yaml to ${OUTPUT_FILE}"
        mv worker.yaml "${OUTPUT_FILE}"
    else
        echo "Error: worker.yaml was not generated"
    fi
    
    rm "$PATCH_FILE"
done

# Clean up
rm -f talosconfig "$BASE_CP_FILE" "$BASE_WORKER_FILE" 2>/dev/null || true

echo -e "\nGenerated files in $MATCHBOX_ASSETS:"
ls -l "$MATCHBOX_ASSETS"
