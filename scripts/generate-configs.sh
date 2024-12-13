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

# Verify required environment variables
for var in CLUSTER_NAME CLUSTER_ENDPOINT CLUSTER_DNS_DOMAIN CLUSTER_POD_SUBNET CLUSTER_SERVICE_SUBNET; do
    if [ -z "${!var}" ]; then
        echo "Error: $var environment variable must be set"
        exit 1
    fi
done

# Default to not wiping disks if not specified
WIPE_DISK=${WIPE_DISK:-false}

echo "Generating Talos configurations..."
echo "Cluster Name: $CLUSTER_NAME"
echo "Endpoint: $CLUSTER_ENDPOINT"
echo "DNS Domain: $CLUSTER_DNS_DOMAIN"
echo "Pod Subnet: $CLUSTER_POD_SUBNET"
echo "Service Subnet: $CLUSTER_SERVICE_SUBNET"
echo "Wipe Disk: $WIPE_DISK"

# Create base config files
BASE_CP_FILE=$(mktemp)
cat > "$BASE_CP_FILE" << EOF
machine:
  type: controlplane
  install:
    disk: /dev/sda
    wipe: ${WIPE_DISK}
EOF

BASE_WORKER_FILE=$(mktemp)
cat > "$BASE_WORKER_FILE" << EOF
machine:
  type: worker
  install:
    disk: /dev/sda
    wipe: ${WIPE_DISK}
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
CERT_SANS=$(IFS=,; echo "[${CONTROL_PLANE_IPS[*]}, \"api.${CLUSTER_NAME}\"]")

# Function to validate config
validate_config() {
    local config_file="$1"
    local node_type="$2"
    echo "Validating ${node_type} config..."
    if ! talosctl validate -c "$config_file" -v; then
        echo "Error: Configuration validation failed for ${node_type}"
        return 1
    fi
    echo "Configuration validation successful for ${node_type}"
}

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
    },
    "cluster": {
        "network": {
            "podSubnets": ["${CLUSTER_POD_SUBNET}"],
            "serviceSubnets": ["${CLUSTER_SERVICE_SUBNET}"]
        }
    }
}
EOF
    
    echo "Generating controlplane config with talosctl..."
    talosctl gen config \
        --output-types controlplane \
        --config-patch "$(cat $BASE_CP_FILE)" \
        --config-patch "$(cat $PATCH_FILE)" \
        --with-docs=false \
        --dns-domain "${CLUSTER_DNS_DOMAIN}" \
        "${CLUSTER_NAME}" \
        "${CLUSTER_ENDPOINT}"
    
    # Validate the generated config
    validate_config "controlplane.yaml" "controlplane-${HOSTNAME}" || exit 1
    
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
    },
    "cluster": {
        "network": {
            "podSubnets": ["${CLUSTER_POD_SUBNET}"],
            "serviceSubnets": ["${CLUSTER_SERVICE_SUBNET}"]
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
        --dns-domain "${CLUSTER_DNS_DOMAIN}" \
        "${CLUSTER_NAME}" \
        "${CLUSTER_ENDPOINT}"
    
    # Validate the generated config
    validate_config "worker.yaml" "worker-${HOSTNAME}" || exit 1
    
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
