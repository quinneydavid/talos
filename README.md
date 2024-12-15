# Talos Cluster Configuration

This repository contains the configuration for a Talos-based Kubernetes cluster using PXE boot with TFTP.

## Overview

The system uses a simple, secure approach to manage Talos configurations:

- Single network configuration file for all nodes
- Configurations with secrets generated at runtime
- Automatic validation of generated configs
- Dynamic node discovery and configuration via PXE boot
- GitOps-based configuration management using Flux

## Structure

```
.
├── clusters/                   # GitOps configuration
│   └── homelab/               # Homelab environment
│       ├── infrastructure/    # Core infrastructure components
│       │   └── kube-vip/     # Load balancer configuration
│       ├── apps/             # Application deployments
│       └── config/           # Cluster-wide configurations
├── configs/                   # Configuration files
│   ├── network-config.yaml   # Node and network configuration
│   └── storage-class.yaml    # Storage class for Synology CSI
├── docker/                   # Docker configurations
│   ├── docker-compose.yml    # Docker Compose configuration
│   ├── Dockerfile.matchbox   # HTTP server for Talos configs
│   └── Dockerfile.matchbox-tftp # TFTP server for PXE boot
└── scripts/                  # Utility scripts
    ├── generate-configs.sh   # Config generation script
    └── bootstrap-flux.sh     # Flux bootstrap script
```

## GitOps Configuration

The cluster uses Flux for GitOps-based configuration management. The structure is organized as follows:

### Infrastructure
Core cluster components managed by Flux:
- kube-vip: Load balancing for control plane and services
- (Add other infrastructure components here)

### Apps
Application deployments managed by Flux:
- Place application manifests here
- Automatically deployed after infrastructure is ready

### Config
Cluster-wide configurations:
- NetworkPolicies
- PodSecurityPolicies
- Resource quotas
- Other cluster-wide settings

### Bootstrapping Flux

After cluster initialization:

1. Install Flux:
```bash
./scripts/bootstrap-flux.sh
```

2. Monitor deployments:
```bash
flux get kustomizations
```

[Rest of existing README content remains unchanged below this point]

## Configuration

[... rest of the existing content ...]
