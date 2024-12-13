#!/bin/sh

# Script to generate Talos configurations using talosctl
# This generates configs with secrets that should only be stored on the matchbox server

set -e

# Directory setup
MATCHBOX_ASSETS="/var/lib/matchbox/assets"
MATCHBOX_PROFILES="/var/lib/matchbox/profiles"
MATCHBOX_GROUPS="/var/lib/matchbox/groups"
mkdir -p "$MATCHBOX_ASSETS" "$MATCHBOX_PROFILES" "$MATCHBOX_GROUPS"

# Ensure yq is available
if ! command -v yq > /dev/null 2>&1; then
    echo "yq is required but not installed"
    exit 1
fi

# Verify required environment variables
for var in CLUSTER_NAME CLUSTER_ENDPOINT CLUSTER_DNS_DOMAIN CLUSTER_POD_SUBNET CLUSTER_SERVICE_SUBNET; do
    eval val=\$$var
    if [ -z "$val" ]; then
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

# Function to create profile
create_profile() {
    local node_id="$1"
    local node_type="$2"
    local profile_path="${MATCHBOX_PROFILES}/${node_id}-profile.json"
    
    # Determine config path based on node type
    if [ "$node_type" = "controlplane" ]; then
        config_path="controlplane-${node_id}.yaml"
    else
        config_path="worker-${node_id}.yaml"
    fi
    
    cat > "$profile_path" << EOF
{
  "id": "${node_id}-profile",
  "name": "Talos ${node_type} Node ${node_id}",
  "boot": {
    "kernel": "vmlinuz",
    "initrd": ["initramfs.xz"],
    "args": [
      "initrd=initramfs.xz",
      "init_on_alloc=1",
      "slab_nomerge",
      "pti=on",
      "console=tty0",
      "console=ttyS0",
      "printk.devkmsg=on",
      "talos.platform=metal",
      "talos.config=http://matchbox.lan:8080/assets/${config_path}"
    ]
  }
}
EOF
}

# Function to create group
create_group() {
    local node_id="$1"
    local mac="$2"
    local group_path="${MATCHBOX_GROUPS}/${node_id}.json"
    
    cat > "$group_path" << EOF
{
    "id": "${node_id}",
    "name": "Node ${node_id}",
    "profile": "${node_id}-profile",
    "selector": {
      "mac": "${mac}"
    }
}
EOF
}

# Generate matchbox profiles and groups
echo "Generating matchbox profiles and groups..."
for node_id in $(yq e '.nodes | keys | .[]' /configs/network-config.yaml); do
    echo "Processing matchbox config for node: $node_id"
    
    # Get node type and MAC address
    node_type=$(yq e ".nodes.${node_id}.type" /configs/network-config.yaml)
    mac=$(yq e ".nodes.${node_id}.mac" /configs/network-config.yaml)
    
    # Create profile and group files
    create_profile "$node_id" "$node_type"
    create_group "$node_id" "$mac"
    
    echo "Created matchbox profile and group for $node_id"
done

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

# Read global network settings
GATEWAY=$(yq e '.network.gateway' /configs/network-config.yaml)
NETMASK=$(yq e '.network.netmask' /configs/network-config.yaml)
NAMESERVERS=$(yq e '.network.nameservers | join(",")' /configs/network-config.yaml)

# Get all control plane nodes
CONTROL_PLANE_IPS=""
for node in $(yq e '.nodes[] | select(.type == "controlplane") | .ip' /configs/network-config.yaml); do
    if [ -z "$CONTROL_PLANE_IPS" ]; then
        CONTROL_PLANE_IPS="\"$node\""
    else
        CONTROL_PLANE_IPS="$CONTROL_PLANE_IPS,\"$node\""
    fi
done

# Create CERT_SANS with IPs and cluster API
CERT_SANS="[${CONTROL_PLANE_IPS}, \"api.${CLUSTER_NAME}\"]"

# Function to validate config
validate_config() {
    local config_file="$1"
    local node_type="$2"
    echo "Validating ${node_type} config..."
    if ! talosctl validate --mode container -c "$config_file"; then
        echo "Error: Configuration validation failed for ${node_type}"
        return 1
    fi
    echo "Configuration validation successful for ${node_type}"
}

# Generate configs for all nodes
for node in $(yq e '.nodes | keys | .[]' /configs/network-config.yaml); do
    echo "Generating config for ${node}..."
    
    # Extract node metadata
    NODE_TYPE=$(yq e ".nodes.${node}.type" /configs/network-config.yaml)
    NODE_IP=$(yq e ".nodes.${node}.ip" /configs/network-config.yaml)
    STORAGE_IP=$(yq e ".nodes.${node}.storage_ip" /configs/network-config.yaml)
    HOSTNAME=$(yq e ".nodes.${node}.hostname" /configs/network-config.yaml)
    MAC_ADDRESS=$(yq e ".nodes.${node}.mac" /configs/network-config.yaml)
    
    echo "Extracted metadata for ${HOSTNAME}:"
    echo "  IP: ${NODE_IP}"
    echo "  Storage IP: ${STORAGE_IP}"
    echo "  Gateway: ${GATEWAY}"
    echo "  Nameservers: ${NAMESERVERS}"
    echo "  MAC Address: ${MAC_ADDRESS}"
    
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
                    "deviceSelector": {
                        "hardwareAddr": "${MAC_ADDRESS}"
                    },
                    "addresses": ["${NODE_IP}/24"],
                    "routes": [{"network": "0.0.0.0/0", "gateway": "${GATEWAY}"}]
                }
            ]
        }$(if [ "$NODE_TYPE" = "controlplane" ]; then echo ", \"certSANs\": ${CERT_SANS}"; fi)
    },
    "cluster": {
        "network": {
            "podSubnets": ["${CLUSTER_POD_SUBNET}"],
            "serviceSubnets": ["${CLUSTER_SERVICE_SUBNET}"]
        }
    }
}
EOF
    
    echo "Generating ${NODE_TYPE} config with talosctl..."
    if [ "$WIPE_DISK" = "true" ]; then
        FORCE_FLAG="--force"
    else
        FORCE_FLAG=""
    fi
    
    if [ "$NODE_TYPE" = "controlplane" ]; then
        BASE_FILE="$BASE_CP_FILE"
        OUTPUT_TYPE="controlplane"
        CONFIG_FILE="controlplane.yaml"
    else
        BASE_FILE="$BASE_WORKER_FILE"
        OUTPUT_TYPE="worker"
        CONFIG_FILE="worker.yaml"
    fi
    
    talosctl gen config \
        $FORCE_FLAG \
        --output-types $OUTPUT_TYPE \
        --config-patch "$(cat $BASE_FILE)" \
        --config-patch "$(cat $PATCH_FILE)" \
        --with-docs=false \
        --dns-domain "${CLUSTER_DNS_DOMAIN}" \
        "${CLUSTER_NAME}" \
        "${CLUSTER_ENDPOINT}"
    
    # Validate the generated config
    validate_config "$CONFIG_FILE" "${NODE_TYPE}-${HOSTNAME}" || exit 1
    
    OUTPUT_FILE="${MATCHBOX_ASSETS}/${NODE_TYPE}-${HOSTNAME}.yaml"
    if [ -f "$CONFIG_FILE" ]; then
        echo "Moving ${CONFIG_FILE} to ${OUTPUT_FILE}"
        mv "$CONFIG_FILE" "${OUTPUT_FILE}"
    else
        echo "Error: ${CONFIG_FILE} was not generated"
    fi
    
    rm "$PATCH_FILE"
done

# Generate talosconfig and move it to assets
echo "Generating talosconfig..."
talosctl gen config \
    --output-types talosconfig \
    --with-docs=false \
    --dns-domain "${CLUSTER_DNS_DOMAIN}" \
    "${CLUSTER_NAME}" \
    "${CLUSTER_ENDPOINT}"

if [ -f talosconfig ]; then
    echo "Moving talosconfig to ${MATCHBOX_ASSETS}/talosconfig"
    mv talosconfig "${MATCHBOX_ASSETS}/talosconfig"
    
    # Create a log file with talosconfig location and export instructions
    cat > "${MATCHBOX_ASSETS}/talosconfig.info" << EOF
Talos configuration file location:
--------------------------------
Container path: ${MATCHBOX_ASSETS}/talosconfig

To export the talosconfig to your local machine, run:
--------------------------------------------------
cd talos/docker && docker cp docker_matchbox_1:/var/lib/matchbox/assets/talosconfig ../tmp/talosconfig

Then you can use it with talosctl:
--------------------------------
cd talos && talosctl --talosconfig tmp/talosconfig --endpoints <NODE_IP> --nodes <NODE_IP> <command>
Example: talosctl --talosconfig tmp/talosconfig --endpoints 192.168.86.210 --nodes 192.168.86.210 version
EOF
    
    echo "Created talosconfig.info with location and export instructions"
else
    echo "Error: talosconfig was not generated"
fi

# Clean up temporary files
rm -f "$BASE_CP_FILE" "$BASE_WORKER_FILE" 2>/dev/null || true

echo -e "\nGenerated files in $MATCHBOX_ASSETS:"
ls -l "$MATCHBOX_ASSETS"

# Display the contents of talosconfig.info
if [ -f "${MATCHBOX_ASSETS}/talosconfig.info" ]; then
    echo -e "\nTalosconfig information:"
    cat "${MATCHBOX_ASSETS}/talosconfig.info"
fi
