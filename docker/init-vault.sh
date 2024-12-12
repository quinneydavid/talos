#!/bin/sh
set -e

# Wait for Vault to be ready
until vault status > /dev/null 2>&1; do
    echo "Waiting for Vault to start..."
    sleep 1
done

# Check if secrets engine is already enabled
if ! vault secrets list | grep -q '^secret/'; then
    echo "Enabling KV secrets engine..."
    vault secrets enable -path=secret kv
else
    echo "KV secrets engine already enabled"
fi

# Generate temporary Talos configs to extract secrets
echo "Generating temporary Talos configs..."
talosctl gen config --output-dir /tmp talos-test https://192.168.86.241:6443

# Store Talos PKI secrets
echo "Storing PKI secrets in Vault..."
vault kv put secret/talos/pki \
    ca_crt="$(cat /tmp/controlplane.yaml | grep 'crt:' | head -1 | awk '{print $2}')" \
    ca_key="$(cat /tmp/controlplane.yaml | grep 'key:' | head -1 | awk '{print $2}')" \
    cluster_ca_crt="$(cat /tmp/controlplane.yaml | grep 'crt:' | tail -1 | awk '{print $2}')"

# Store Talos cluster secrets
echo "Storing cluster secrets in Vault..."
vault kv put secret/talos/cluster \
    cluster_id="$(cat /tmp/controlplane.yaml | grep 'id:' | awk '{print $2}')" \
    cluster_secret="$(cat /tmp/controlplane.yaml | grep 'secret:' | awk '{print $2}')" \
    bootstrap_token="$(cat /tmp/controlplane.yaml | grep 'token:' | head -1 | awk '{print $2}')" \
    machine_token="$(cat /tmp/controlplane.yaml | grep 'token:' | tail -1 | awk '{print $2}')"

# Clean up
rm -rf /tmp/controlplane.yaml /tmp/worker.yaml /tmp/talosconfig

echo "Vault initialization complete!"
