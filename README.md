# Talos Kubernetes Cluster Setup

This repository contains configuration templates and setup files for deploying a Talos Kubernetes cluster.

## Prerequisites

- HashiCorp Vault server
- Docker and Docker Compose
- Access to a DHCP/PXE boot environment

## Vault Setup

Before running the matchbox service, you need to set up the following secrets in Vault:

1. Start a Vault dev server (for testing) or use your production Vault server:
```bash
# For testing only
vault server -dev
```

2. Set up the required secrets:
```bash
# Create a KV secrets engine
vault secrets enable -path=secret kv

# Store Talos PKI secrets
vault kv put secret/talos/pki \
  ca_crt="$(talosctl gen config --output-dir /tmp talos-test https://example.com:6443 && cat /tmp/controlplane.yaml | yq .machine.ca.crt)" \
  ca_key="$(cat /tmp/controlplane.yaml | yq .machine.ca.key)" \
  cluster_ca_crt="$(cat /tmp/controlplane.yaml | yq .cluster.ca.crt)"

# Store Talos cluster secrets
vault kv put secret/talos/cluster \
  cluster_id="$(cat /tmp/controlplane.yaml | yq .cluster.id)" \
  cluster_secret="$(cat /tmp/controlplane.yaml | yq .cluster.secret)" \
  bootstrap_token="$(cat /tmp/controlplane.yaml | yq .cluster.token)" \
  machine_token="$(cat /tmp/controlplane.yaml | yq .machine.token)"

# Clean up temporary files
rm -rf /tmp/controlplane.yaml /tmp/worker.yaml /tmp/talosconfig
```

## Environment Setup

Create a `.env` file in the docker directory with your Vault configuration:

```bash
VAULT_ADDR=http://vault:8200
VAULT_TOKEN=your-vault-token
```

## Running the Services

Start the matchbox and TFTP services:

```bash
cd docker
docker-compose up --build
```

The services will:
1. Fetch the latest Talos release
2. Download config templates from this repository
3. Fetch secrets from Vault
4. Generate the final configurations
5. Serve configs via matchbox and TFTP

## Security Notes

- Never commit secrets or certificates to the repository
- Use environment variables for Vault connection details
- Store all sensitive data in Vault
- Rotate secrets and certificates periodically
- Monitor Vault audit logs for secret access

## Network Configuration

The matchbox service provides:
- HTTP on port 8080 for metadata and assets
- TFTP on port 69 for PXE boot

Ensure your DHCP server is configured to:
- Provide next-server pointing to your TFTP server
- Set filename to "lpxelinux.0"
