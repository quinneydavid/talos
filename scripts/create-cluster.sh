#!/bin/bash
#
# Talos Kubernetes Cluster Bootstrap Script
# 
# This script bootstraps a Talos Kubernetes cluster by:
# - Retrieving the talosconfig from the matchbox container
# - Bootstrapping the first control plane node
# - Waiting for the cluster to be ready
# - Generating kubeconfig for cluster access
# - Optionally bootstrapping Flux for GitOps management
#
# Prerequisites:
# - Docker with matchbox container running
# - talosctl installed
# - kubectl installed
# - yq installed
# - Network configuration in place
#
# Usage:
#   ./create-cluster.sh             # Basic cluster creation
#   ./create-cluster.sh --with-flux # Cluster creation with Flux bootstrapping

set -euo pipefail

# Display help information
show_help() {
    echo "Talos Kubernetes Cluster Bootstrap Script"
    echo ""
    echo "Usage:"
    echo "  $0                     # Basic cluster creation"
    echo "  $0 --with-flux         # Cluster creation with Flux bootstrapping"
    echo "  $0 --help              # Display this help message"
    echo ""
    echo "Environment Variables:"
    echo "  CLUSTER_NAME           # Cluster name (default: k8s.lan)"
    echo "  CLUSTER_ENDPOINT       # Cluster endpoint (default: https://api.k8s.lan:6443)"
    echo "  BASE_PATH              # Base path for the project (default: auto-detected)"
    echo "  TALOS_UPGRADE_VERSION  # Talos version to upgrade to (default: v1.9.0)"
    echo "  MAX_RETRIES            # Maximum number of retries (default: 60)"
    echo "  TIMEOUT                # Timeout in seconds (default: 300)"
    echo ""
    echo "Examples:"
    echo "  TALOS_UPGRADE_VERSION=v1.9.1 $0  # Use a specific Talos version"
    echo "  BASE_PATH=/opt/talos $0          # Use a custom base path"
    exit 0
}

# Check for help flag
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
fi

# Default cluster name
CLUSTER_ID=${CLUSTER_ID:-prod}

# Display help information
show_help() {
    echo "Talos Kubernetes Cluster Bootstrap Script"
    echo ""
    echo "Usage:"
    echo "  $0 [options]"
    echo ""
    echo "Options:"
    echo "  --cluster=CLUSTER_ID  Specify which cluster to bootstrap (default: prod)"
    echo "  --with-flux           Bootstrap Flux for GitOps management"
    echo "  --help                Display this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Bootstrap the prod cluster (default)"
    echo "  $0 --cluster=dev      # Bootstrap the dev cluster"
    echo "  $0 --with-flux        # Bootstrap the prod cluster with Flux"
    exit 0
}

# Parse command line arguments
WITH_FLUX=false
for arg in "$@"; do
    case $arg in
        --cluster=*)
            CLUSTER_ID="${arg#*=}"
            shift
            ;;
        --with-flux)
            WITH_FLUX=true
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

# Default values and configuration
MAX_RETRIES=60  # 5 minutes with 5-second intervals
TIMEOUT=300     # 5 minutes total timeout
BASE_PATH=${BASE_PATH:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"}
TALOS_PATH="${BASE_PATH}/talos"
NETWORK_CONFIG_PATH="/var/lib/matchbox/network-config.yaml"
TALOS_UPGRADE_VERSION=${TALOS_UPGRADE_VERSION:-"v1.9.0"}
TALOS_UPGRADE_IMAGE="factory.talos.dev/installer/c9078f9419961640c712a8bf2bb9174933dfcf1da383fd8ea2b7dc21493f8bac"

# Create tmp directory if it doesn't exist
mkdir -p "${TALOS_PATH}/tmp"

# Read configuration from network-config.yaml
echo "Reading configuration from network-config.yaml for cluster: ${CLUSTER_ID}..."
if [ -f "${NETWORK_CONFIG_PATH}" ]; then
    # Check if the specified cluster exists
    if ! yq e ".clusters.${CLUSTER_ID}" "${NETWORK_CONFIG_PATH}" > /dev/null 2>&1; then
        echo "Error: Cluster '${CLUSTER_ID}' not found in network-config.yaml"
        echo "Available clusters:"
        yq e '.clusters | keys | .[]' "${NETWORK_CONFIG_PATH}"
        exit 1
    fi
    
    # Get cluster configuration
    CLUSTER_NAME=$(yq e ".clusters.${CLUSTER_ID}.cluster.name" "${NETWORK_CONFIG_PATH}")
    CLUSTER_ENDPOINT=$(yq e ".clusters.${CLUSTER_ID}.cluster.endpoint" "${NETWORK_CONFIG_PATH}")
    CONTROL_PLANE_VIP=$(yq e ".clusters.${CLUSTER_ID}.network.vip" "${NETWORK_CONFIG_PATH}")
    
    echo "Using configuration from network-config.yaml:"
    echo "  Cluster ID: ${CLUSTER_ID}"
    echo "  Cluster Name: ${CLUSTER_NAME}"
    echo "  Cluster Endpoint: ${CLUSTER_ENDPOINT}"
    echo "  Control Plane VIP: ${CONTROL_PLANE_VIP}"
else
    echo "Warning: network-config.yaml not found at ${NETWORK_CONFIG_PATH}"
    echo "Using default or environment variable values..."
    CLUSTER_NAME=${CLUSTER_NAME:-k8s.lan}
    CLUSTER_ENDPOINT=${CLUSTER_ENDPOINT:-https://api.k8s.lan:6443}
fi

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

# Verify network configuration file exists
if [ ! -f "${NETWORK_CONFIG_PATH}" ]; then
    echo "Error: Network configuration file not found at ${NETWORK_CONFIG_PATH}"
    echo "The network configuration file is required for cluster creation."
    exit 1
fi

# Extract node information from network configuration
echo "Extracting node information from network configuration for cluster: ${CLUSTER_ID}..."

# Get control plane nodes
CONTROL_PLANE_NODES=$(yq e ".clusters.${CLUSTER_ID}.nodes[] | select(.type == \"controlplane\") | .hostname" "${NETWORK_CONFIG_PATH}")
CONTROL_PLANE_ARRAY=()
while IFS= read -r node; do
    CONTROL_PLANE_ARRAY+=("$node")
    # Perform DNS lookup for the node
    node_ip=$(perform_dns_lookup "$node")
    if [ -n "$node_ip" ]; then
        echo "Control plane node ${node} resolved to ${node_ip}"
    fi
done <<< "$CONTROL_PLANE_NODES"

# Get worker nodes
WORKER_NODES=$(yq e ".clusters.${CLUSTER_ID}.nodes[] | select(.type == \"worker\") | .hostname" "${NETWORK_CONFIG_PATH}")
WORKER_ARRAY=()
while IFS= read -r node; do
    WORKER_ARRAY+=("$node")
    # Perform DNS lookup for the node
    node_ip=$(perform_dns_lookup "$node")
    if [ -n "$node_ip" ]; then
        echo "Worker node ${node} resolved to ${node_ip}"
    fi
done <<< "$WORKER_NODES"

# Set first control plane node
if [ ${#CONTROL_PLANE_ARRAY[@]} -gt 0 ]; then
    CONTROL_PLANE_1_NAME="${CONTROL_PLANE_ARRAY[0]}"
    echo "First control plane node: ${CONTROL_PLANE_1_NAME}"
else
    echo "Error: No control plane nodes found in network configuration for cluster ${CLUSTER_ID}"
    exit 1
fi

# Create comma-separated list of all nodes
ALL_NODES=("${CONTROL_PLANE_ARRAY[@]}" "${WORKER_ARRAY[@]}")
ALL_NODE_NAMES=$(IFS=,; echo "${ALL_NODES[*]}")
echo "All nodes: ${ALL_NODE_NAMES}"

# Function to check if a command succeeds with timeout and retries
wait_for_success() {
    local cmd="$1"
    local desc="$2"
    local retries=0
    local start_time=$(date +%s)

    echo "Waiting for $desc..."
    while true; do
        if eval "$cmd" &>/dev/null; then
            echo "✅ $desc is ready"
            return 0
        fi

        retries=$((retries + 1))
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))
        
        if [ $elapsed -ge $TIMEOUT ]; then
            echo "❌ Timeout waiting for $desc after ${TIMEOUT} seconds"
            return 1
        fi

        if [ $retries -ge $MAX_RETRIES ]; then
            echo "❌ Max retries ($MAX_RETRIES) reached waiting for $desc"
            return 1
        fi

        echo "⏳ Waiting for $desc... (${retries}/${MAX_RETRIES} attempts, ${elapsed}s elapsed)"
        sleep 5
    done
}

# Function to check etcd health on the first control plane node
check_etcd_health() {
    local output
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        output=$(talosctl --nodes-by-hostname ${CONTROL_PLANE_1_NAME} service etcd 2>&1)
        local status=$?
        
        if [ $status -ne 0 ]; then
            echo "Attempt $attempt/$max_attempts: Failed to get etcd status: $output"
            attempt=$((attempt + 1))
            [ $attempt -le $max_attempts ] && sleep 5
            continue
        fi
        
        if echo "$output" | grep -q "STATE.*Running" && echo "$output" | grep -q "HEALTH.*OK"; then
            echo "Etcd is healthy on ${CONTROL_PLANE_1_NAME}"
            return 0
        fi
        
        echo "Attempt $attempt/$max_attempts: Etcd is not healthy yet"
        attempt=$((attempt + 1))
        [ $attempt -le $max_attempts ] && sleep 5
    done
    
    echo "Failed to verify etcd health after $max_attempts attempts"
    return 1
}

# Function to check and setup Flux prerequisites
check_flux_prerequisites() {
    echo "Checking Flux prerequisites..."
    
    # Install SOPS if not present
    if ! command -v sops >/dev/null 2>&1; then
        echo "Installing SOPS..."
        SOPS_VERSION=$(curl -s https://api.github.com/repos/mozilla/sops/releases/latest | jq -r .tag_name)
        curl -Lo sops "https://github.com/mozilla/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64"
        chmod +x sops
        sudo mv sops /usr/local/bin/
        echo "✅ SOPS installed successfully"
    else
        echo "✅ SOPS already installed"
    fi

    # Install age if not present
    if ! command -v age-keygen >/dev/null 2>&1; then
        echo "Installing age..."
        AGE_VERSION=$(curl -s https://api.github.com/repos/FiloSottile/age/releases/latest | jq -r .tag_name)
        curl -Lo age.tar.gz "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz"
        tar xf age.tar.gz
        sudo mv age/age* /usr/local/bin/
        rm -rf age age.tar.gz
        echo "✅ Age installed successfully"
    else
        echo "✅ Age already installed"
    fi

    # Setup age key directory
    AGE_KEY_DIR="$HOME/.config/sops/age"
    mkdir -p "$AGE_KEY_DIR"
    echo "✅ Age key directory setup at $AGE_KEY_DIR"

    # Generate age key if it doesn't exist
    if [ ! -f "$AGE_KEY_DIR/keys.txt" ]; then
        echo "Generating new age key..."
        age-keygen -o "$AGE_KEY_DIR/keys.txt"
        
        # Extract public key
        PUBLIC_KEY=$(age-keygen -y "$AGE_KEY_DIR/keys.txt")
        
        # Create .sops.yaml
        cat >"${TALOS_PATH}/.sops.yaml" <<EOF
creation_rules:
  - path_regex: .*.enc.yaml
    encrypted_regex: ^(data|stringData)$
    age: >-
      ${PUBLIC_KEY}
EOF
        
        echo "✅ SOPS setup complete!"
        echo "  - Private key location: $AGE_KEY_DIR/keys.txt"
        echo "  - Public key: $PUBLIC_KEY"
        echo "  - SOPS configuration written to ${TALOS_PATH}/.sops.yaml"
        echo ""
        echo "⚠️  IMPORTANT: Backup your private key ($AGE_KEY_DIR/keys.txt) securely!"
        echo "    This key will be needed to decrypt secrets and should never be committed to git."
    else
        echo "✅ Age key already exists at $AGE_KEY_DIR/keys.txt"
    fi

    # Install GitHub CLI if not present
    if ! command -v gh &>/dev/null; then
        echo "Installing GitHub CLI..."
        type -p curl >/dev/null || (sudo apt update && sudo apt install curl -y)
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
        && sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
        && sudo apt update \
        && sudo apt install gh -y
        echo "✅ GitHub CLI installed successfully"
    else
        echo "✅ GitHub CLI already installed"
    fi

    # Setup GitHub authentication if needed
    if ! gh auth status &>/dev/null; then
        echo "GitHub authentication required. Running gh auth login..."
        if ! gh auth login --web; then
            echo "❌ GitHub authentication failed"
            return 1
        fi
        echo "✅ GitHub authentication successful"
    else
        echo "✅ Already authenticated with GitHub"
    fi

    # Start SSH agent if not running
    if [ -z "${SSH_AUTH_SOCK:-}" ]; then
        echo "Starting SSH agent..."
        eval $(ssh-agent) >/dev/null
        echo "✅ SSH agent started"
    else
        echo "✅ SSH agent already running"
    fi

    # Add SSH key if not already added
    if ! ssh-add -l 2>/dev/null | grep -q "GitHub CLI"; then
        echo "Adding SSH key to agent..."
        if ssh-add ~/.ssh/id_ed25519 2>/dev/null; then
            echo "✅ SSH key added to agent"
        else
            echo "⚠️  Could not add SSH key to agent, but continuing anyway"
        fi
    else
        echo "✅ SSH key already added to agent"
    fi

    echo "✅ All Flux prerequisites checked"
    return 0
}

# Cleanup function for error handling
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "❌ Script failed with exit code $exit_code"
        echo "Checking service status for debugging..."
        talosctl --nodes-by-hostname ${CONTROL_PLANE_1_NAME} services || true
        
        echo ""
        echo "Troubleshooting tips:"
        echo "1. Check if all nodes are powered on and accessible"
        echo "2. Verify network configuration in ${NETWORK_CONFIG_PATH}"
        echo "3. Check Docker container logs: docker logs docker_matchbox_1"
        echo "4. Examine talosconfig at ${TALOSCONFIG}"
    else
        echo "✅ Script completed successfully"
    fi
    exit $exit_code
}

trap cleanup EXIT

# Main script
echo "=== Starting Talos Cluster Bootstrap Process ==="
echo "Base path: ${BASE_PATH}"
echo "Talos path: ${TALOS_PATH}"
echo "Network config: ${NETWORK_CONFIG_PATH}"
echo "Cluster name: ${CLUSTER_NAME}"
echo "Cluster endpoint: ${CLUSTER_ENDPOINT}"
echo ""

# Get talosconfig from matchbox container
echo "Retrieving talosconfig for cluster ${CLUSTER_ID} from matchbox container..."
if ! docker cp docker_matchbox_1:/var/lib/matchbox/assets/${CLUSTER_ID}-talosconfig "${TALOS_PATH}/tmp/talosconfig"; then
    echo "❌ Failed to copy talosconfig from matchbox container"
    echo "Check if the matchbox container is running: docker ps | grep matchbox"
    echo "Also verify that the ${CLUSTER_ID}-talosconfig file exists in the container"
    exit 1
fi
echo "✅ Retrieved talosconfig successfully"

# Export TALOSCONFIG to use the one we just copied
export TALOSCONFIG="${TALOS_PATH}/tmp/talosconfig"
echo "Using talosconfig at ${TALOSCONFIG}"

# Wait for first control plane to be ready
echo "Waiting for first control plane node (${CONTROL_PLANE_1_NAME}) to be ready..."
if ! wait_for_success "talosctl --nodes-by-hostname ${CONTROL_PLANE_1_NAME} version" "first control plane node"; then
    echo "❌ Failed to connect to first control plane node (${CONTROL_PLANE_1_NAME})"
    echo "Check if the node is powered on and network is properly configured"
    exit 1
fi

# Check if bootstrap is needed
echo "Checking etcd status on ${CONTROL_PLANE_1_NAME}..."
if ! check_etcd_health; then
    echo "Etcd is not healthy, attempting bootstrap..."
    
    # Retry bootstrap up to 3 times if it fails
    max_bootstrap_attempts=3
    bootstrap_attempt=1
    bootstrap_success=false
    
    while [ $bootstrap_attempt -le $max_bootstrap_attempts ] && [ "$bootstrap_success" = false ]; do
        echo "Bootstrap attempt $bootstrap_attempt/$max_bootstrap_attempts..."
        if talosctl --nodes-by-hostname ${CONTROL_PLANE_1_NAME} bootstrap; then
            echo "✅ Bootstrap command executed successfully"
            bootstrap_success=true
        else
            echo "❌ Bootstrap attempt $bootstrap_attempt failed"
            bootstrap_attempt=$((bootstrap_attempt + 1))
            [ $bootstrap_attempt -le $max_bootstrap_attempts ] && sleep 10
        fi
    done
    
    if [ "$bootstrap_success" = false ]; then
        echo "❌ Failed to bootstrap cluster after $max_bootstrap_attempts attempts"
        exit 1
    fi
else
    echo "✅ Etcd is already healthy, skipping bootstrap"
fi

# Wait for etcd to be healthy
if ! wait_for_success "check_etcd_health" "etcd to be healthy"; then
    echo "❌ Failed waiting for etcd to become healthy"
    exit 1
fi

echo "✅ First control plane node bootstrap complete!"

# Verify cluster health
echo "Verifying cluster health..."
if ! wait_for_success "talosctl --nodes-by-hostname ${CONTROL_PLANE_1_NAME} health --wait-timeout 30s" "cluster health check"; then
    echo "❌ Cluster health check failed"
    exit 1
fi

# Generate kubeconfig
echo "Generating kubeconfig..."
if ! talosctl --nodes-by-hostname ${CONTROL_PLANE_1_NAME} kubeconfig --force; then
    echo "❌ Failed to generate kubeconfig"
    exit 1
fi
echo "✅ Kubeconfig generated successfully"

# Verify kubectl access
echo "Verifying kubectl access..."
if ! wait_for_success "kubectl get nodes" "kubectl access"; then
    echo "❌ Failed to verify kubectl access"
    exit 1
fi

# Verify all nodes are ready
echo "Waiting for all nodes to be ready..."
if ! wait_for_success "kubectl wait --for=condition=ready nodes --all --timeout=300s" "all nodes to be ready"; then
    echo "⚠️ Not all nodes are ready, but continuing anyway"
    kubectl get nodes
else
    echo "✅ All nodes are ready"
    kubectl get nodes
fi

# Upgrade nodes with iSCSI support
echo "Upgrading nodes with iSCSI support..."
echo "Using Talos version: ${TALOS_UPGRADE_VERSION}"
if ! talosctl upgrade --image ${TALOS_UPGRADE_IMAGE}:${TALOS_UPGRADE_VERSION} --nodes-by-hostname ${ALL_NODE_NAMES}; then
    echo "❌ Failed to upgrade nodes"
    exit 1
fi
echo "✅ Node upgrade initiated successfully"

# Wait for nodes to be ready after upgrade
echo "Waiting for nodes to be ready after upgrade..."
if ! wait_for_success "kubectl wait --for=condition=ready nodes --all --timeout=300s" "all nodes to be ready after upgrade"; then
    echo "⚠️ Not all nodes are ready after upgrade, but continuing anyway"
    kubectl get nodes
else
    echo "✅ All nodes are ready after upgrade"
    kubectl get nodes
fi

# Verify core components
echo "Verifying core components..."
if ! wait_for_success "kubectl wait --for=condition=ready pods --all -n kube-system --timeout=300s" "core components to be ready"; then
    echo "⚠️ Not all core components are ready, but continuing anyway"
    kubectl get pods -n kube-system
else
    echo "✅ All core components are ready"
fi

# Bootstrap Flux if requested
if [ "${1:-}" = "--with-flux" ]; then
    echo "Checking Flux prerequisites..."
    if ! check_flux_prerequisites; then
        echo "❌ Flux prerequisites not met. Please address the issues above and try again."
        exit 1
    fi

    echo "All prerequisites met. Bootstrapping Flux..."
    if ! "${TALOS_PATH}/scripts/bootstrap-flux.sh"; then
        echo "❌ Failed to bootstrap Flux"
        exit 1
    fi

    echo "Waiting for Flux components to be ready..."
    if ! wait_for_success "kubectl wait --for=condition=ready pods --all -n flux-system --timeout=300s" "Flux components to be ready"; then
        echo "⚠️ Not all Flux components are ready, but continuing anyway"
        kubectl get pods -n flux-system
    else
        echo "✅ Flux components are ready"
    fi

    echo "✅ Flux bootstrap completed successfully!"
fi

echo "Cluster bootstrap completed successfully!"
echo "Cluster is ready to use - kubeconfig has been generated and all components are healthy"
kubectl get nodes -o wide

if [ "${1:-}" = "--with-flux" ]; then
    echo ""
    echo "Flux is configured and running. Your cluster is now managed by GitOps!"
    echo "You can monitor Flux with: flux get all"
fi
