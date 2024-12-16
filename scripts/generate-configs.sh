#!/bin/sh

# Script to generate Talos configurations using talosctl
# This generates configs with secrets that should only be stored on the matchbox server

set -e

# Directory setup
MATCHBOX_ASSETS="/var/lib/matchbox/assets"
TMP_DIR="/tmp/talos"
mkdir -p "$MATCHBOX_ASSETS" "$TMP_DIR"

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

# Read kube-vip manifest
KUBE_VIP_MANIFEST=$(cat /var/lib/matchbox/configs/kube-vip.yaml)

# Create base config files
BASE_CP_FILE=$(mktemp)
cat > "$BASE_CP_FILE" << EOF
machine:
  type: controlplane
  install:
    disk: /dev/sda
    wipe: ${WIPE_DISK}
  kubelet:
    extraArgs:
      node-labels: node.kubernetes.io/control-plane=
  features:
    kubePrism:
      enabled: true
  network:
    interfaces:
      - deviceSelector:
          busPath: "0:0"
        vip:
          ip: ${CLUSTER_ENDPOINT}
  bootstrap:
    enabled: true
cluster:
  apiServer:
    admissionControl:
      - name: PodSecurity
        configuration:
          defaults:
            enforce: "baseline"
            enforce-version: "latest"
            audit: "restricted"
            audit-version: "latest"
            warn: "restricted"
            warn-version: "latest"
  controllerManager:
    extraArgs:
      bind-address: 0.0.0.0
  scheduler:
    extraArgs:
      bind-address: 0.0.0.0
  proxy:
    disabled: false
    extraArgs:
      bind-address: 0.0.0.0
  discovery:
    enabled: true
    registries:
      kubernetes:
        disabled: false
  etcd:
    advertisedSubnets:
      - ${CLUSTER_SERVICE_SUBNET}
  inlineManifests:
    - name: kube-vip
      contents: |
        ${KUBE_VIP_MANIFEST}
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
GATEWAY=$(yq e '.network.gateway' /var/lib/matchbox/network-config.yaml)
NETMASK=$(yq e '.network.netmask' /var/lib/matchbox/network-config.yaml)
NAMESERVERS=$(yq e '.network.nameservers | join(",")' /var/lib/matchbox/network-config.yaml)

# Get all control plane nodes
CONTROL_PLANE_IPS=""
for node in $(yq e '.nodes[] | select(.type == "controlplane") | .ip' /var/lib/matchbox/network-config.yaml); do
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

# Generate base configs with talosconfig
echo "Generating base configurations..."
if [ "$WIPE_DISK" = "true" ]; then
    FORCE_FLAG="--force"
else
    FORCE_FLAG=""
fi

# Generate initial configs with talosconfig
talosctl gen config \
    $FORCE_FLAG \
    --output-types controlplane,worker,talosconfig \
    --with-docs=false \
    --dns-domain "${CLUSTER_DNS_DOMAIN}" \
    "${CLUSTER_NAME}" \
    "${CLUSTER_ENDPOINT}"

# Process and move generated configs
for node in $(yq e '.nodes | keys | .[]' /var/lib/matchbox/network-config.yaml); do
    echo "Processing config for ${node}..."
    
    # Extract node metadata
    NODE_TYPE=$(yq e ".nodes.${node}.type" /var/lib/matchbox/network-config.yaml)
    NODE_IP=$(yq e ".nodes.${node}.ip" /var/lib/matchbox/network-config.yaml)
    STORAGE_IP=$(yq e ".nodes.${node}.storage_ip" /var/lib/matchbox/network-config.yaml)
    HOSTNAME=$(yq e ".nodes.${node}.hostname" /var/lib/matchbox/network-config.yaml)
    MAC_ADDRESS=$(yq e ".nodes.${node}.mac" /var/lib/matchbox/network-config.yaml)
    
    OUTPUT_FILE="${MATCHBOX_ASSETS}/${NODE_TYPE}-${HOSTNAME}.yaml"
    
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
    
    if [ "$NODE_TYPE" = "controlplane" ]; then
        CONFIG_FILE="controlplane.yaml"
    else
        CONFIG_FILE="worker.yaml"
    fi
    
    # Apply the patch to the config
    yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$CONFIG_FILE" "$PATCH_FILE" > "$OUTPUT_FILE"
    
    # Validate the patched config
    validate_config "$OUTPUT_FILE" "${NODE_TYPE}-${HOSTNAME}" || exit 1
    
    rm "$PATCH_FILE"
done

# Move talosconfig to assets directory
if [ -f talosconfig ]; then
    echo "Moving talosconfig to ${MATCHBOX_ASSETS}/talosconfig"
    mv talosconfig "${MATCHBOX_ASSETS}/talosconfig"
    # Also copy to tmp dir for cluster readiness check
    cp "${MATCHBOX_ASSETS}/talosconfig" "${TMP_DIR}/talosconfig"
    
    # Create a log file with talosconfig location and export instructions
    cat > "${MATCHBOX_ASSETS}/talosconfig.info" << EOF
Talos configuration file location:
--------------------------------
Container path: ${MATCHBOX_ASSETS}/talosconfig

To export the talosconfig to your local machine run:
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
rm -f "$BASE_CP_FILE" "$BASE_WORKER_FILE" controlplane.yaml worker.yaml 2>/dev/null || true

# Create .ready file to signal TFTP server
touch "${MATCHBOX_ASSETS}/.ready"

echo -e "\nGenerated files in $MATCHBOX_ASSETS:"
ls -l "$MATCHBOX_ASSETS"

# Display the contents of talosconfig.info
if [ -f "${MATCHBOX_ASSETS}/talosconfig.info" ]; then
    echo -e "\nTalosconfig information:"
    cat "${MATCHBOX_ASSETS}/talosconfig.info"
fi

# Function to wait for cluster readiness
wait_for_cluster() {
    echo "Waiting for cluster to be ready..."
    
    # Get first control plane IP
    FIRST_CP=$(yq e '.nodes[] | select(.type == "controlplane") | .ip' /var/lib/matchbox/network-config.yaml | head -n1)
    
    # Get all control plane IPs
    CP_IPS=$(yq e '.nodes[] | select(.type == "controlplane") | .ip' /var/lib/matchbox/network-config.yaml | tr '\n' ',' | sed 's/,$//')
    
    # Get all worker IPs
    WORKER_IPS=$(yq e '.nodes[] | select(.type == "worker") | .ip' /var/lib/matchbox/network-config.yaml | tr '\n' ',' | sed 's/,$//')
    
    # Wait for cluster health
    echo "Waiting for cluster health..."
    until talosctl --talosconfig "${TMP_DIR}/talosconfig" --endpoints "$FIRST_CP" health \
        --control-plane-nodes "$CP_IPS" \
        --worker-nodes "$WORKER_IPS" \
        --wait-timeout 10m; do
        sleep 10
    done
    
    # Get kubeconfig
    echo "Retrieving kubeconfig..."
    talosctl --talosconfig "${TMP_DIR}/talosconfig" --endpoints "$FIRST_CP" kubeconfig .
    
    echo "Cluster is ready!"
}

# Function to bootstrap Flux
bootstrap_flux() {
    echo "Bootstrapping Flux..."
    
    # Install Flux CLI if not present
    if ! command -v flux >/dev/null 2>&1; then
        curl -s https://fluxcd.io/install.sh | sudo bash
    fi
    
    # Bootstrap Flux
    flux bootstrap github \
        --owner=quinneydavid \
        --repository=talos \
        --branch=main \
        --path=clusters/homelab \
        --personal
    
    echo "Flux bootstrapped successfully!"
}

# Wait for cluster and bootstrap Flux
wait_for_cluster
bootstrap_flux
