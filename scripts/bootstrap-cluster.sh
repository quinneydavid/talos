#!/bin/bash
set -e

# This script automates the bootstrapping of a Talos cluster
# It uses the DNS suffix and connectivity checks to ensure proper configuration

# Default values
CLUSTER_ID=${CLUSTER_ID:-prod}
DNS_SUFFIX=${DNS_SUFFIX:-.lan}
TALOSCONFIG=${TALOSCONFIG:-$HOME/.talos/config}
KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
TIMEOUT=${TIMEOUT:-300}
VERBOSE=${VERBOSE:-true}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --cluster-id)
      CLUSTER_ID="$2"
      shift 2
      ;;
    --dns-suffix)
      DNS_SUFFIX="$2"
      shift 2
      ;;
    --talosconfig)
      TALOSCONFIG="$2"
      shift 2
      ;;
    --kubeconfig)
      KUBECONFIG="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --quiet)
      VERBOSE=false
      shift
      ;;
    --help)
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  --cluster-id ID        Specify cluster ID (default: prod)"
      echo "  --dns-suffix SUFFIX    Specify DNS suffix for nodes (default: .lan)"
      echo "  --talosconfig PATH     Path to talosconfig file (default: $HOME/.talos/config)"
      echo "  --kubeconfig PATH      Path to kubeconfig file (default: $HOME/.kube/config)"
      echo "  --timeout SECONDS      Bootstrap timeout in seconds (default: 300)"
      echo "  --quiet                Reduce verbosity"
      echo "  --help                 Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Function to log messages
log() {
  local level=$1
  local message=$2
  
  if [[ "$level" == "INFO" ]]; then
    echo -e "\033[0;32m[INFO]\033[0m $message"
  elif [[ "$level" == "WARN" ]]; then
    echo -e "\033[0;33m[WARN]\033[0m $message"
  elif [[ "$level" == "ERROR" ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m $message"
  elif [[ "$level" == "DEBUG" ]] && [[ "$VERBOSE" == "true" ]]; then
    echo -e "\033[0;36m[DEBUG]\033[0m $message"
  fi
}

# Check if talosconfig exists
if [[ ! -f "$TALOSCONFIG" ]]; then
  log "ERROR" "Talosconfig not found at $TALOSCONFIG"
  exit 1
fi

# Extract endpoints from talosconfig
log "INFO" "Reading endpoints from talosconfig..."
CONTEXT=$(yq e '.context' "$TALOSCONFIG" 2>/dev/null || echo "")

if [[ -z "$CONTEXT" ]]; then
  log "ERROR" "No context found in talosconfig"
  exit 1
fi

log "INFO" "Found context: $CONTEXT"

# Try to get discovery endpoints
DISCOVERY_ENDPOINTS=$(yq e ".contexts.\"$CONTEXT\".discoveryEndpoints[]" "$TALOSCONFIG" 2>/dev/null || echo "")

if [[ -n "$DISCOVERY_ENDPOINTS" ]]; then
  log "INFO" "Found discovery endpoints in talosconfig"
  
  # Add each discovery endpoint to the nodes array
  while IFS= read -r endpoint; do
    # Strip any existing suffix if it matches our DNS_SUFFIX
    endpoint=$(echo "$endpoint" | sed "s/${DNS_SUFFIX}$//")
    CONTROL_PLANE_NODES+=("$endpoint")
  done <<< "$DISCOVERY_ENDPOINTS"
else
  # Try to get regular endpoints
  ENDPOINTS=$(yq e ".contexts.\"$CONTEXT\".endpoints[]" "$TALOSCONFIG" 2>/dev/null || echo "")
  
  if [[ -n "$ENDPOINTS" ]]; then
    log "INFO" "Found endpoints in talosconfig"
    
    # Add each endpoint to the nodes array
    while IFS= read -r endpoint; do
      # Check if it's an IP address
      if [[ "$endpoint" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "DEBUG" "Endpoint $endpoint is an IP address"
        IP_NODES+=("$endpoint")
      else
        # Strip any existing suffix if it matches our DNS_SUFFIX
        endpoint=$(echo "$endpoint" | sed "s/${DNS_SUFFIX}$//")
        CONTROL_PLANE_NODES+=("$endpoint")
      fi
    done <<< "$ENDPOINTS"
  fi
fi

# If still no nodes, use default control plane nodes
if [[ ${#CONTROL_PLANE_NODES[@]} -eq 0 && ${#IP_NODES[@]} -eq 0 ]]; then
  log "INFO" "No nodes found in talosconfig, using default control plane nodes"
  CONTROL_PLANE_NODES=("${CLUSTER_ID}cp1" "${CLUSTER_ID}cp2" "${CLUSTER_ID}cp3")
fi

# Check connectivity to control plane nodes
log "INFO" "Checking connectivity to control plane nodes..."
REACHABLE_NODES=()

for node in "${CONTROL_PLANE_NODES[@]}"; do
  node_with_suffix="${node}${DNS_SUFFIX}"
  
  log "INFO" "Checking node: $node_with_suffix"
  
  # Check if node is reachable (force IPv4)
  if ping -c 1 -W 2 -4 "$node_with_suffix" &>/dev/null; then
    log "INFO" "✅ Node $node_with_suffix is reachable via IPv4"
    
    # Check if Talos API port is open
    if nc -z -w 5 "$node_with_suffix" 50000 &>/dev/null; then
      log "INFO" "✅ Talos API port is open on $node_with_suffix"
      REACHABLE_NODES+=("$node_with_suffix")
    else
      log "WARN" "⚠️ Talos API port is not reachable on $node_with_suffix"
    fi
  else
    log "WARN" "⚠️ Node $node_with_suffix is not reachable"
    
    # Try without suffix (force IPv4)
    if ping -c 1 -W 2 -4 "$node" &>/dev/null; then
      log "INFO" "✅ Node $node is reachable via IPv4 (without suffix)"
      
      # Check if Talos API port is open
      if nc -z -w 5 "$node" 50000 &>/dev/null; then
        log "INFO" "✅ Talos API port is open on $node"
        REACHABLE_NODES+=("$node")
      else
        log "WARN" "⚠️ Talos API port is not reachable on $node"
      fi
    else
      log "ERROR" "❌ Node $node is not reachable with or without suffix"
    fi
  fi
done

# Check connectivity to IP nodes
for ip in "${IP_NODES[@]}"; do
  log "INFO" "Checking IP: $ip"
  
  # Check if IP is reachable (force IPv4)
  if ping -c 1 -W 2 -4 "$ip" &>/dev/null; then
    log "INFO" "✅ IP $ip is reachable via IPv4"
    
    # Check if Talos API port is open
    if nc -z -w 5 "$ip" 50000 &>/dev/null; then
      log "INFO" "✅ Talos API port is open on $ip"
      REACHABLE_NODES+=("$ip")
    else
      log "WARN" "⚠️ Talos API port is not reachable on $ip"
    fi
  else
    log "ERROR" "❌ IP $ip is not reachable"
  fi
done

# Check if we have any reachable nodes
if [[ ${#REACHABLE_NODES[@]} -eq 0 ]]; then
  log "ERROR" "No reachable nodes found. Cannot bootstrap cluster."
  exit 1
fi

# Select the first reachable node as the bootstrap node
BOOTSTRAP_NODE=${REACHABLE_NODES[0]}
log "INFO" "Selected bootstrap node: $BOOTSTRAP_NODE"

# Get the IPv4 address of the bootstrap node to avoid certificate hostname issues
# First try using getent to get only IPv4 addresses
BOOTSTRAP_NODE_IP=$(getent ahostsv4 "$BOOTSTRAP_NODE" | grep STREAM | head -n 1 | awk '{ print $1 }')

# If getent fails, try using dig with the +short +ipv4 options
if [[ -z "$BOOTSTRAP_NODE_IP" ]]; then
  BOOTSTRAP_NODE_IP=$(dig +short +ipv4 "$BOOTSTRAP_NODE")
fi

# If dig fails, try using nslookup and grep for IPv4 addresses
if [[ -z "$BOOTSTRAP_NODE_IP" ]]; then
  BOOTSTRAP_NODE_IP=$(nslookup "$BOOTSTRAP_NODE" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | grep -v "^127\." | head -n 1)
fi

# If we still don't have an IP and the node name looks like an IPv4, use it directly
if [[ -z "$BOOTSTRAP_NODE_IP" && "$BOOTSTRAP_NODE" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  BOOTSTRAP_NODE_IP="$BOOTSTRAP_NODE"
fi

# If we still don't have an IPv4 address, try to ping the node and capture the IP
if [[ -z "$BOOTSTRAP_NODE_IP" ]]; then
  BOOTSTRAP_NODE_IP=$(ping -c 1 -4 "$BOOTSTRAP_NODE" 2>/dev/null | grep "PING" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -n 1)
fi

if [[ -z "$BOOTSTRAP_NODE_IP" ]]; then
  log "ERROR" "Could not resolve IPv4 address for $BOOTSTRAP_NODE"
  exit 1
fi

log "INFO" "Using IPv4 address for bootstrap node: $BOOTSTRAP_NODE_IP"

# Bootstrap the cluster
log "INFO" "Bootstrapping the cluster..."

# Extract the hostname without the suffix for certificate validation
BOOTSTRAP_NODE_NAME=$(echo "$BOOTSTRAP_NODE" | sed "s/${DNS_SUFFIX}$//")
log "INFO" "Using node name without suffix for certificate validation: $BOOTSTRAP_NODE_NAME"

# Force using the bootstrap node's IP address directly and explicitly set the endpoint
# This prevents talosctl from trying to use the VIP which isn't active yet
# Using IP address avoids certificate hostname issues
if talosctl --nodes="$BOOTSTRAP_NODE_NAME" --endpoints="$BOOTSTRAP_NODE_IP" --talosconfig="$TALOSCONFIG" bootstrap; then
  log "INFO" "✅ Bootstrap command executed successfully"
else
  log "ERROR" "❌ Bootstrap command failed"
  exit 1
fi

# Wait for the cluster to be ready
log "INFO" "Waiting for the cluster to be ready (this may take a few minutes)..."
start_time=$(date +%s)
end_time=$((start_time + TIMEOUT))

while true; do
  current_time=$(date +%s)
  
  if [[ $current_time -gt $end_time ]]; then
    log "ERROR" "Timeout waiting for cluster to be ready"
    exit 1
  fi
  
  if talosctl --nodes="$BOOTSTRAP_NODE_NAME" --endpoints="$BOOTSTRAP_NODE_IP" --talosconfig="$TALOSCONFIG" health --wait-timeout=30s &>/dev/null; then
    log "INFO" "✅ Cluster is healthy"
    break
  else
    log "DEBUG" "Cluster not ready yet, waiting..."
    sleep 10
  fi
done

# Generate kubeconfig
log "INFO" "Generating kubeconfig..."
if talosctl --nodes="$BOOTSTRAP_NODE_NAME" --endpoints="$BOOTSTRAP_NODE_IP" --talosconfig="$TALOSCONFIG" kubeconfig --force "$KUBECONFIG"; then
  log "INFO" "✅ Kubeconfig generated successfully at $KUBECONFIG"
else
  log "ERROR" "❌ Failed to generate kubeconfig"
  exit 1
fi

# Check if kubectl is available
if ! command -v kubectl &>/dev/null; then
  log "WARN" "kubectl not found, skipping Kubernetes checks"
else
  # Check Kubernetes nodes
  log "INFO" "Checking Kubernetes nodes..."
  if kubectl --kubeconfig="$KUBECONFIG" get nodes &>/dev/null; then
    NODE_COUNT=$(kubectl --kubeconfig="$KUBECONFIG" get nodes -o name | wc -l)
    READY_COUNT=$(kubectl --kubeconfig="$KUBECONFIG" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{","}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' | grep -c "True")
    
    log "INFO" "✅ Kubernetes API is accessible"
    log "INFO" "  Total nodes: $NODE_COUNT"
    log "INFO" "  Ready nodes: $READY_COUNT"
  else
    log "WARN" "⚠️ Unable to access Kubernetes API"
  fi
fi

log "INFO" "Cluster bootstrap complete!"
log "INFO" "You can now use talosctl and kubectl to interact with your cluster:"
log "INFO" "  talosctl --nodes=$BOOTSTRAP_NODE_NAME --endpoints=$BOOTSTRAP_NODE_IP --talosconfig=$TALOSCONFIG health"
log "INFO" "  kubectl --kubeconfig=$KUBECONFIG get nodes"

# Export configuration files for host use
log "INFO" "Exporting configuration files to host..."

# Copy talosconfig if needed
if [[ -f "$TALOSCONFIG" && "$TALOSCONFIG" != "/root/.talos/config" ]]; then
  log "INFO" "Copying talosconfig to /root/.talos/config"
  mkdir -p /root/.talos
  cp "$TALOSCONFIG" /root/.talos/config
  chmod 644 /root/.talos/config || log "WARN" "Failed to set permissions on talosconfig"
  log "INFO" "Talos config exported to ~/.talos/config"
else
  log "INFO" "Talos config already at ~/.talos/config"
fi

# Ensure kubeconfig has proper permissions
if [[ -f "$KUBECONFIG" ]]; then
  chmod 644 "$KUBECONFIG" || log "WARN" "Failed to set permissions on kubeconfig"
  log "INFO" "Kube config permissions set at ~/.kube/config"
else
  log "WARN" "Kubeconfig not found at $KUBECONFIG, skipping permission update"
fi

log "INFO" "Configuration files exported and configured for host use"
