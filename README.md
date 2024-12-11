# Talos Kubernetes Cluster Setup

This repository contains configuration templates and setup files for deploying a Talos Kubernetes cluster.

## Overview

The setup includes:
- Matchbox for serving Talos configurations
- TFTP server for PXE boot
- Integrated HashiCorp Vault (talos-vault) for secret management
- Automated secret generation and storage

## Components

### talos-vault
A dedicated Vault instance for storing Talos secrets:
- Machine CA certificates and keys
- Cluster secrets (tokens, IDs)
- Bootstrap tokens

### talos-vault-init
Automatically initializes the vault with required secrets:
- Generates temporary Talos configs
- Extracts and stores secrets in vault
- Cleans up temporary files

### matchbox
Serves Talos configurations and assets:
- Fetches secrets from vault
- Generates node-specific configs
- Serves configs via HTTP

### matchbox-tftp
Provides PXE boot support:
- Serves boot files via TFTP
- Integrates with matchbox for config delivery

## Prerequisites

- Docker and Docker Compose
- Access to a DHCP/PXE boot environment

## Quick Start

1. Clone this repository:
```bash
git clone https://github.com/quinneydavid/talos.git
cd talos/docker
```

2. Start the services:
```bash
docker-compose up --build
```

The setup will:
1. Start talos-vault in dev mode
2. Initialize vault with generated Talos secrets
3. Start matchbox and TFTP services
4. Configure everything for PXE boot

## Network Configuration

The services provide:
- HTTP (matchbox) on port 8080 for metadata and assets
- TFTP on port 69 for PXE boot
- Vault UI on port 8200 (dev mode)

Ensure your DHCP server is configured to:
- Provide next-server pointing to your TFTP server
- Set filename to "lpxelinux.0"

## Security Notes

- talos-vault runs in dev mode for testing
- All secrets are automatically generated and stored in vault
- Secrets are never written to disk or committed to git
- For production:
  - Use a proper Vault installation
  - Configure proper authentication
  - Enable audit logging
  - Use TLS for all services

## Vault Structure

Secrets are organized in vault as follows:

```
secret/
└── talos/
    ├── pki/
    │   ├── ca_crt
    │   ├── ca_key
    │   └── cluster_ca_crt
    └── cluster/
        ├── cluster_id
        ├── cluster_secret
        ├── bootstrap_token
        └── machine_token
```

## Troubleshooting

1. Check vault status:
```bash
docker-compose exec talos-vault vault status
```

2. View vault secrets:
```bash
docker-compose exec talos-vault vault kv list secret/talos
```

3. Check matchbox logs:
```bash
docker-compose logs -f matchbox
```

4. Check TFTP logs:
```bash
docker-compose logs -f matchbox-tftp
