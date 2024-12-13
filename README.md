# Talos Cluster Configuration

This repository contains the configuration for a Talos-based Kubernetes cluster using PXE boot with Matchbox.

## Overview

- Uses Matchbox for PXE boot configuration
- Generates Talos node configurations using talosctl
- Maintains base configurations in version control
- Keeps generated configs with secrets only on the Matchbox server

## Structure

```
.
├── configs/                    # Base Talos configurations (no secrets)
│   ├── controlplane.yaml      # Control plane node base config
│   └── worker.yaml            # Worker node base config
├── docker/                    # Docker configurations
│   ├── docker-compose.yml     # Docker Compose configuration
│   ├── Dockerfile.matchbox    # Matchbox server with talosctl
│   └── Dockerfile.matchbox-tftp # TFTP server for PXE boot
├── matchbox/                  # Matchbox configurations
│   ├── groups/               # Node group definitions
│   └── profiles/             # Boot profiles
└── scripts/                   # Utility scripts
    └── generate-configs.sh    # Config generation script

## Usage

1. Base configurations (controlplane.yaml and worker.yaml) are stored in the configs directory and can be customized as needed.

2. Start the services:
   ```bash
   cd docker
   docker-compose up -d
   ```

3. The matchbox container will:
   - Download required Talos assets
   - Generate node configurations using talosctl
   - Serve configurations via PXE boot

## Configuration

- Edit configs/controlplane.yaml and configs/worker.yaml for base configuration changes
- Node-specific settings are managed in matchbox/groups/
- Network boot configuration is in matchbox/profiles/

## Security

- Base configurations in this repo contain no secrets
- Generated configurations with secrets are only stored on the Matchbox server
- Secrets are generated by talosctl during container startup
