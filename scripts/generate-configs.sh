#!/bin/bash

# Script to generate Talos configurations using talosctl
# This generates configs with secrets that should only be stored on the matchbox server

set -e

# Default cluster name
CLUSTER_ID=${CLUSTER_ID:-prod}

# Display help information
show_help() {
    echo "Talos Configuration Generator"
    echo ""
    echo "Usage:"
    echo "  $0 [options]"
    echo ""
    echo "Options:"
    echo "  --cluster=CLUSTER_ID  Specify which cluster to configure (default: prod)"
    echo "  --help                Display this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Configure the prod cluster (default)"
    echo "  $0 --cluster=dev      # Configure the dev cluster"
    exit 0
}

# Parse command line arguments
for arg in "$@"; do
    case $arg in
        --cluster=*)
            CLUSTER_ID="${arg#*=}"
            shift
            ;;
        --help)
            show_help
            ;;
        *)
            echo "Unknown option: $arg"
            show_help
            ;;
    esac
done

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

# Read configuration from network-config.yaml
echo "Reading configuration from network-config.yaml for cluster: ${CLUSTER_ID}..."
if [ ! -f /var/lib/matchbox/network-config.yaml ]; then
    echo "Error: network-config.yaml not found at /var/lib/matchbox/network-config.yaml"
    exit 1
fi

# Check if the specified cluster exists
if ! yq e ".clusters.${CLUSTER_ID}" /var/lib/matchbox/network-config.yaml > /dev/null 2>&1; then
    echo "Error: Cluster '${CLUSTER_ID}' not found in network-config.yaml"
    echo "Available clusters:"
    yq e '.clusters | keys | .[]' /var/lib/matchbox/network-config.yaml
    exit 1
fi

# Get cluster configuration from network-config.yaml
CLUSTER_NAME=$(yq e ".clusters.${CLUSTER_ID}.cluster.name" /var/lib/matchbox/network-config.yaml)
CLUSTER_ENDPOINT=$(yq e ".clusters.${CLUSTER_ID}.cluster.endpoint" /var/lib/matchbox/network-config.yaml)
CLUSTER_DNS_DOMAIN=$(yq e ".clusters.${CLUSTER_ID}.cluster.dns_domain" /var/lib/matchbox/network-config.yaml)
CLUSTER_POD_SUBNET=$(yq e ".clusters.${CLUSTER_ID}.cluster.pod_subnet" /var/lib/matchbox/network-config.yaml)
CLUSTER_SERVICE_SUBNET=$(yq e ".clusters.${CLUSTER_ID}.cluster.service_subnet" /var/lib/matchbox/network-config.yaml)
CONTROL_PLANE_VIP=$(yq e ".clusters.${CLUSTER_ID}.network.vip" /var/lib/matchbox/network-config.yaml)

# Verify required configuration values
for var_name in "CLUSTER_NAME" "CLUSTER_ENDPOINT" "CLUSTER_DNS_DOMAIN" "CLUSTER_POD_SUBNET" "CLUSTER_SERVICE_SUBNET" "CONTROL_PLANE_VIP"; do
    eval val=\$$var_name
    if [ -z "$val" ]; then
        echo "Error: $var_name not found in network-config.yaml for cluster ${CLUSTER_ID}"
        exit 1
    fi
done

# Default to not wiping disks if not specified
WIPE_DISK=${WIPE_DISK:-false}

echo "Generating Talos configurations for cluster: ${CLUSTER_ID}"
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

# Function to perform DNS lookup
perform_dns_lookup() {
    local hostname="$1"
    local ip=""
    
    echo "Performing DNS lookup for ${hostname}..."
    
    # Try to resolve hostname using getent
    ip=$(getent hosts "${hostname}" 2>/dev/null | awk '{print $1}' | head -n 1)
    
    if [ -z "$ip" ]; then
        # Try to resolve using dig if getent fails
        if command -v dig > /dev/null 2>&1; then
            ip=$(dig +short "${hostname}" 2>/dev/null | head -n 1)
        fi
    fi
    
    if [ -z "$ip" ]; then
        # Try to resolve using nslookup if dig fails
        if command -v nslookup > /dev/null 2>&1; then
            ip=$(nslookup "${hostname}" 2>/dev/null | grep -A1 'Name:' | grep 'Address:' | awk '{print $2}' | head -n 1)
        fi
    fi
    
    if [ -n "$ip" ]; then
        echo "✅ Resolved ${hostname} to ${ip}"
    else
        echo "⚠️ Could not resolve ${hostname} via DNS. Using hostname for discovery."
    fi
    
    echo "$ip"
}

# Process each node in the specified cluster
for node in $(yq e ".clusters.${CLUSTER_ID}.nodes | keys | .[]" /var/lib/matchbox/network-config.yaml); do
    hostname=$(yq e ".clusters.${CLUSTER_ID}.nodes.${node}.hostname" /var/lib/matchbox/network-config.yaml)
    mac=$(yq e ".clusters.${CLUSTER_ID}.nodes.${node}.mac" /var/lib/matchbox/network-config.yaml)
    type=$(yq e ".clusters.${CLUSTER_ID}.nodes.${node}.type" /var/lib/matchbox/network-config.yaml)
    
    # Perform DNS lookup for the node's hostname
    node_ip=$(perform_dns_lookup "${hostname}")
    
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
    
    output_file="$MATCHBOX_ASSETS/${CLUSTER_ID}-${type}-${hostname}.yaml"
    
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
CONTROL_PLANE_NODES=$(yq e ".clusters.${CLUSTER_ID}.nodes[] | select(.type == \"controlplane\") | .hostname" /var/lib/matchbox/network-config.yaml)

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
cp "$TMP_DIR/talosconfig" "$MATCHBOX_ASSETS/${CLUSTER_ID}-talosconfig"

# Cleanup
rm -f "$TMP_DIR/controlplane.yaml" "$TMP_DIR/worker.yaml" "$TMP_DIR/talosconfig" "$TMP_DIR/network.patch.yaml" "$TMP_DIR/ca.txt" "$TMP_DIR/crt.txt" "$TMP_DIR/key.txt"

echo "Configuration generation complete for cluster: ${CLUSTER_ID}!"
