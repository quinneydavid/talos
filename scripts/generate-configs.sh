#!/bin/bash

# Script to generate Talos configurations using talosctl
# This generates configs with secrets that should only be stored on the matchbox server

set -e

# Directory setup
MATCHBOX_ASSETS="/var/lib/matchbox/assets"
TMP_DIR="/tmp/talos"
mkdir -p "$MATCHBOX_ASSETS" "$TMP_DIR"

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

# Ensure yq is available
if ! command -v yq > /dev/null 2>&1; then
    echo "yq is required but not installed"
    exit 1
fi

# Verify required environment variables
for var in CLUSTER_NAME CLUSTER_ENDPOINT CLUSTER_DNS_DOMAIN CLUSTER_POD_SUBNET CLUSTER_SERVICE_SUBNET CONTROL_PLANE_VIP; do
    eval val=\$$var
    if [ -z "$val" ]; then
        echo "Error: $var environment variable must be set"
        exit 1
    fi
done

# Default to not wiping disks if not specified
WIPE_DISK=${WIPE_DISK:-false}

# Get VIP from network configuration
CONTROL_PLANE_VIP=$(yq e '.network.vip' /var/lib/matchbox/network-config.yaml || echo "$CONTROL_PLANE_VIP")

echo "Generating Talos configurations..."
echo "Cluster Name: $CLUSTER_NAME"
echo "Endpoint: $CLUSTER_ENDPOINT"
echo "Control Plane VIP: $CONTROL_PLANE_VIP"
echo "DNS Domain: $CLUSTER_DNS_DOMAIN"
echo "Pod Subnet: $CLUSTER_POD_SUBNET"
echo "Service Subnet: $CLUSTER_SERVICE_SUBNET"
echo "Wipe Disk: $WIPE_DISK"

# Generate base configs
echo "Generating base cluster configuration..."
talosctl gen config --output-dir "$TMP_DIR" "$CLUSTER_NAME" "$CLUSTER_ENDPOINT"

# Process each node
for node in $(yq e '.nodes | keys | .[]' /var/lib/matchbox/network-config.yaml); do
    hostname=$(yq e ".nodes.${node}.hostname" /var/lib/matchbox/network-config.yaml)
    mac=$(yq e ".nodes.${node}.mac" /var/lib/matchbox/network-config.yaml)
    type=$(yq e ".nodes.${node}.type" /var/lib/matchbox/network-config.yaml)
    
    if [ "$type" = "controlplane" ]; then
        base_file="$TMP_DIR/controlplane.yaml"
        
        # Create network config patch for control plane
        cat > "$TMP_DIR/network.patch.yaml" << EOF
machine:
  type: controlplane
  network:
    hostname: "${hostname}"
    interfaces:
      - deviceSelector:
          busPath: "0000:00:03.0"
          hardwareAddr: "${mac}"
        dhcp: true
        vip:
          ip: ${CONTROL_PLANE_VIP}
      - deviceSelector:
          busPath: "0000:00:04.0"
        dhcp: true
  discovery:
    enabled: true
    registries:
      kubernetes:
        disabled: false
      service:
        disabled: false
  install:
    disk: /dev/sda
    wipe: ${WIPE_DISK}
  features:
    hostDNS:
      enabled: true
      forwardKubeDNSToHost: true
cluster:
  network:
    dnsDomain: "${CLUSTER_DNS_DOMAIN}"
    podSubnets:
      - "${CLUSTER_POD_SUBNET}"
    serviceSubnets:
      - "${CLUSTER_SERVICE_SUBNET}"
EOF
    else
        base_file="$TMP_DIR/worker.yaml"
        
        # Create network config patch for worker
        cat > "$TMP_DIR/network.patch.yaml" << EOF
machine:
  type: worker
  network:
    hostname: "${hostname}"
    interfaces:
      - deviceSelector:
          busPath: "0000:00:03.0"
          hardwareAddr: "${mac}"
        dhcp: true
      - deviceSelector:
          busPath: "0000:00:04.0"
        dhcp: true
  discovery:
    enabled: true
    registries:
      kubernetes:
        disabled: false
      service:
        disabled: false
  install:
    disk: /dev/sda
    wipe: ${WIPE_DISK}
  features:
    hostDNS:
      enabled: true
      forwardKubeDNSToHost: true
cluster:
  network:
    dnsDomain: "${CLUSTER_DNS_DOMAIN}"
    podSubnets:
      - "${CLUSTER_POD_SUBNET}"
    serviceSubnets:
      - "${CLUSTER_SERVICE_SUBNET}"
EOF
    fi
    
    output_file="$MATCHBOX_ASSETS/${type}-${hostname}.yaml"
    
    # Preserve version and merge configs
    version=$(yq e '.version' "$base_file")
    yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$base_file" "$TMP_DIR/network.patch.yaml" > "$TMP_DIR/merged.yaml"
    yq e ".version = \"$version\"" -i "$TMP_DIR/merged.yaml"
    mv "$TMP_DIR/merged.yaml" "$output_file"
    
    # Validate the config
    validate_config "$output_file" "$type"
done

# Get all control plane hostnames and add them to talosconfig
echo "Adding control plane endpoints to talosconfig..."
CONTROL_PLANE_NODES=$(yq e '.nodes[] | select(.type == "controlplane") | .hostname' /var/lib/matchbox/network-config.yaml)

# Create a temporary YAML file with the correct structure
cat > "$TMP_DIR/endpoints.yaml" << EOF
context: ${CLUSTER_NAME}
contexts:
  ${CLUSTER_NAME}:
    endpoints:
      - ${CONTROL_PLANE_VIP}
EOF

# Add each hostname as a discovery endpoint
echo "    discoveryEndpoints:" >> "$TMP_DIR/endpoints.yaml"
while IFS= read -r hostname; do
    echo "      - ${hostname}" >> "$TMP_DIR/endpoints.yaml"
done <<< "$CONTROL_PLANE_NODES"

# Add the remaining fields from the original talosconfig
yq e '.contexts[].ca' "$TMP_DIR/talosconfig" > "$TMP_DIR/ca.txt"
yq e '.contexts[].crt' "$TMP_DIR/talosconfig" > "$TMP_DIR/crt.txt"
yq e '.contexts[].key' "$TMP_DIR/talosconfig" > "$TMP_DIR/key.txt"

cat >> "$TMP_DIR/endpoints.yaml" << EOF
    ca: $(cat "$TMP_DIR/ca.txt")
    crt: $(cat "$TMP_DIR/crt.txt")
    key: $(cat "$TMP_DIR/key.txt")
EOF

# Replace the original talosconfig with our new one
mv "$TMP_DIR/endpoints.yaml" "$TMP_DIR/talosconfig"

# Copy talosconfig to assets directory before cleanup
cp "$TMP_DIR/talosconfig" "$MATCHBOX_ASSETS/talosconfig"

# Cleanup
rm -f "$TMP_DIR/controlplane.yaml" "$TMP_DIR/worker.yaml" "$TMP_DIR/talosconfig" "$TMP_DIR/network.patch.yaml" "$TMP_DIR/ca.txt" "$TMP_DIR/crt.txt" "$TMP_DIR/key.txt"

echo "Configuration generation complete!"
