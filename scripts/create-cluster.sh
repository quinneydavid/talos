#!/bin/bash
set -euo pipefail

# Default values
CLUSTER_NAME=${CLUSTER_NAME:-k8s.lan}
CLUSTER_ENDPOINT=${CLUSTER_ENDPOINT:-https://api.k8s.lan:6443}
MAX_RETRIES=60  # 5 minutes with 5-second intervals
TIMEOUT=300     # 5 minutes total timeout

# Node IPs
CONTROL_PLANE_1="192.168.86.211"

# Function to check if a command succeeds
wait_for_success() {
    local cmd="$1"
    local desc="$2"
    local retries=0
    local start_time=$(date +%s)

    echo "Waiting for $desc..."
    while true; do
        if eval "$cmd" &>/dev/null; then
            echo "$desc is ready"
            return 0
        fi

        retries=$((retries + 1))
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))
        
        if [ $elapsed -ge $TIMEOUT ]; then
            echo "Timeout waiting for $desc after ${TIMEOUT} seconds"
            return 1
        fi

        if [ $retries -ge $MAX_RETRIES ]; then
            echo "Max retries ($MAX_RETRIES) reached waiting for $desc"
            return 1
        fi

        echo "Waiting for $desc... (${retries}/${MAX_RETRIES} attempts, ${elapsed}s elapsed)"
        sleep 5
    done
}

# Function to check etcd health
check_etcd_health() {
    local output
    output=$(talosctl --nodes ${CONTROL_PLANE_1} service etcd 2>&1)
    local status=$?
    
    if [ $status -ne 0 ]; then
        echo "Failed to get etcd status: $output"
        return 1
    fi
    
    if echo "$output" | grep -q "STATE.*Running" && echo "$output" | grep -q "HEALTH.*OK"; then
        return 0
    fi
    
    return 1
}

# Function to check and setup Flux prerequisites
check_flux_prerequisites() {
    # Install SOPS if not present
    if ! command -v sops >/dev/null 2>&1; then
        echo "Installing SOPS..."
        SOPS_VERSION=$(curl -s https://api.github.com/repos/mozilla/sops/releases/latest | jq -r .tag_name)
        curl -Lo sops "https://github.com/mozilla/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64"
        chmod +x sops
        sudo mv sops /usr/local/bin/
    fi

    # Install age if not present
    if ! command -v age-keygen >/dev/null 2>&1; then
        echo "Installing age..."
        AGE_VERSION=$(curl -s https://api.github.com/repos/FiloSottile/age/releases/latest | jq -r .tag_name)
        curl -Lo age.tar.gz "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz"
        tar xf age.tar.gz
        sudo mv age/age* /usr/local/bin/
        rm -rf age age.tar.gz
    fi

    # Setup age key directory
    AGE_KEY_DIR="$HOME/.config/sops/age"
    mkdir -p "$AGE_KEY_DIR"

    # Generate age key if it doesn't exist
    if [ ! -f "$AGE_KEY_DIR/keys.txt" ]; then
        echo "Generating new age key..."
        age-keygen -o "$AGE_KEY_DIR/keys.txt"
        
        # Extract public key
        PUBLIC_KEY=$(age-keygen -y "$AGE_KEY_DIR/keys.txt")
        
        # Create .sops.yaml
        cat >.sops.yaml <<EOF
creation_rules:
  - path_regex: .*.enc.yaml
    encrypted_regex: ^(data|stringData)$
    age: >-
      ${PUBLIC_KEY}
EOF
        
        echo "SOPS setup complete!"
        echo "Private key location: $AGE_KEY_DIR/keys.txt"
        echo "Public key: $PUBLIC_KEY"
        echo "SOPS configuration written to .sops.yaml"
        echo ""
        echo "IMPORTANT: Backup your private key ($AGE_KEY_DIR/keys.txt) securely!"
        echo "This key will be needed to decrypt secrets and should never be committed to git."
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
    fi

    # Setup GitHub authentication if needed
    if ! gh auth status &>/dev/null; then
        echo "GitHub authentication required. Running gh auth login..."
        if ! gh auth login --web; then
            echo "GitHub authentication failed"
            return 1
        fi
        echo "GitHub authentication successful"
    fi

    # Start SSH agent if not running
    if [ -z "$SSH_AUTH_SOCK" ]; then
        echo "Starting SSH agent..."
        eval $(ssh-agent)
    fi

    # Add SSH key if not already added
    if ! ssh-add -l | grep -q "GitHub CLI"; then
        echo "Adding SSH key to agent..."
        ssh-add ~/.ssh/id_ed25519
    fi

    return 0
}

# Cleanup function
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "Script failed with exit code $exit_code"
        echo "Checking service status..."
        talosctl --nodes ${CONTROL_PLANE_1} services || true
    fi
    exit $exit_code
}

trap cleanup EXIT

# Main script
echo "Starting cluster bootstrap process..."

# Get talosconfig from matchbox container
echo "Retrieving talosconfig from matchbox container..."
if ! cd /home/david/vscode; then
    echo "Failed to change to /home/david/vscode directory"
    exit 1
fi

if ! docker cp docker_matchbox_1:/var/lib/matchbox/assets/talosconfig talos/tmp/talosconfig; then
    echo "Failed to copy talosconfig from matchbox container"
    exit 1
fi

# Export TALOSCONFIG to use the one we just copied
export TALOSCONFIG=/home/david/vscode/talos/tmp/talosconfig

# Wait for first control plane to be ready
if ! wait_for_success "talosctl --nodes ${CONTROL_PLANE_1} version" "first control plane node"; then
    echo "Failed to connect to first control plane node"
    exit 1
fi

# Check if bootstrap is needed
echo "Checking etcd status..."
if ! check_etcd_health; then
    echo "Etcd is not healthy, attempting bootstrap..."
    if ! talosctl --nodes ${CONTROL_PLANE_1} bootstrap; then
        echo "Failed to bootstrap cluster"
        exit 1
    fi
    echo "Bootstrap command executed successfully"
else
    echo "Etcd is already healthy, skipping bootstrap"
fi

# Wait for etcd to be healthy
if ! wait_for_success "check_etcd_health" "etcd to be healthy"; then
    echo "Failed waiting for etcd to become healthy"
    exit 1
fi

echo "First control plane node bootstrap complete!"

# Verify cluster health
echo "Verifying cluster health..."
if ! wait_for_success "talosctl --nodes ${CONTROL_PLANE_1} health --wait-timeout 30s" "cluster health check"; then
    echo "Cluster health check failed"
    exit 1
fi

# Generate kubeconfig
echo "Generating kubeconfig..."
if ! talosctl --nodes ${CONTROL_PLANE_1} kubeconfig --force; then
    echo "Failed to generate kubeconfig"
    exit 1
fi

# Verify kubectl access
echo "Verifying kubectl access..."
if ! wait_for_success "kubectl get nodes" "kubectl access"; then
    echo "Failed to verify kubectl access"
    exit 1
fi

# Verify all nodes are ready
echo "Waiting for all nodes to be ready..."
if ! wait_for_success "kubectl wait --for=condition=ready nodes --all --timeout=300s" "all nodes to be ready"; then
    echo "Not all nodes are ready"
    exit 1
fi

# Verify core components
echo "Verifying core components..."
if ! wait_for_success "kubectl wait --for=condition=ready pods --all -n kube-system --timeout=300s" "core components to be ready"; then
    echo "Not all core components are ready"
    exit 1
fi

# Bootstrap Flux if requested
if [ "${1:-}" = "--with-flux" ]; then
    echo "Checking Flux prerequisites..."
    if ! check_flux_prerequisites; then
        echo "Flux prerequisites not met. Please address the issues above and try again."
        exit 1
    fi

    echo "All prerequisites met. Bootstrapping Flux..."
    if ! /home/david/vscode/talos/scripts/bootstrap-flux.sh; then
        echo "Failed to bootstrap Flux"
        exit 1
    fi

    echo "Waiting for Flux components to be ready..."
    if ! wait_for_success "kubectl wait --for=condition=ready pods --all -n flux-system --timeout=300s" "Flux components to be ready"; then
        echo "Not all Flux components are ready"
        exit 1
    fi

    echo "Flux bootstrap completed successfully!"
fi

echo "Cluster bootstrap completed successfully!"
echo "Cluster is ready to use - kubeconfig has been generated and all components are healthy"
kubectl get nodes -o wide

if [ "${1:-}" = "--with-flux" ]; then
    echo ""
    echo "Flux is configured and running. Your cluster is now managed by GitOps!"
    echo "You can monitor Flux with: flux get all"
fi
