# Talos Cluster Configuration

This repository contains the configuration for a Talos-based Kubernetes cluster using PXE boot with Matchbox.

## Overview

The system uses a simple, secure approach to manage Talos configurations:

- Base configurations stored in Git (no secrets)
- Node-specific settings in matchbox group files
- Configurations with secrets generated at runtime
- Automatic validation of generated configs

## Structure

```
.
├── configs/                    # Base Talos configurations
│   ├── controlplane.yaml      # Control plane base config
│   ├── worker.yaml            # Worker node base config
│   └── storage-class.yaml     # Storage class for Synology CSI
├── docker/                    # Docker configurations
│   ├── docker-compose.yml     # Docker Compose configuration
│   ├── Dockerfile.matchbox    # Matchbox server with talosctl
│   └── Dockerfile.matchbox-tftp # TFTP server for PXE boot
├── matchbox/                  # Matchbox configurations
│   ├── groups/               # Node group definitions
│   │   ├── cp1.json         # Control plane 1 settings
│   │   ├── cp2.json         # Control plane 2 settings
│   │   ├── cp3.json         # Control plane 3 settings
│   │   ├── worker1.json     # Worker 1 settings
│   │   └── worker2.json     # Worker 2 settings
│   └── profiles/            # Boot profiles
└── scripts/                  # Utility scripts
    └── generate-configs.sh   # Config generation script

## Configuration

### Environment Variables

The cluster configuration is controlled through environment variables in docker-compose.yml:

```yaml
environment:
  - CLUSTER_NAME=k8s.lan
  - CLUSTER_ENDPOINT=https://api.k8s.lan:6443
  - CLUSTER_DNS_DOMAIN=cluster.local
  - CLUSTER_POD_SUBNET=10.244.0.0/16
  - CLUSTER_SERVICE_SUBNET=10.96.0.0/12
  - WIPE_DISK=false  # Set to true to wipe disks during reinstall
```

### Node Configuration

Each node's settings are defined in `matchbox/groups/`. Nodes have dual network interfaces:
- eth0: Primary network (192.168.86.0/24)
- eth1: Storage network (10.44.5.0/24)

Example node configuration:
```json
{
    "id": "cp1",
    "name": "Control Plane Node 1",
    "profile": "control-plane",
    "selector": {
      "mac": "50:6b:8d:96:f7:50"
    },
    "metadata": {
      "ip": "192.168.86.211",        # Primary network IP
      "gateway": "192.168.86.1",
      "netmask": "255.255.255.0",
      "storage_ip": "10.44.5.10",    # Storage network IP
      "hostname": "cp1",
      "nameservers": ["192.168.86.2", "192.168.86.4"]
    }
}
```

### Storage Configuration

The cluster uses a dedicated storage network for Synology CSI:

1. Each node has a storage network interface (eth1) configured via group files
2. Storage IPs are in the 10.44.5.0/24 network:
   - Control plane nodes: 10.44.5.10-12
   - Worker nodes: 10.44.5.20-21
   - Synology NAS: 10.44.5.2

The storage class configuration is defined in `configs/storage-class.yaml`:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: synology-csi
provisioner: csi.synology.com
parameters:
  fsType: ext4
  location: "10.44.5.2"  # Synology NAS IP on storage network
  storage_pool: "volume1"
```

## Usage

### Initial Installation

1. Configure environment variables in docker-compose.yml
2. Start the services:
   ```bash
   cd docker
   docker-compose up -d
   ```

### Configuration Validation

The generate-configs.sh script automatically validates each configuration before deploying:

1. Each generated config is validated using talosctl:
   ```bash
   talosctl validate -c config.yaml -v
   ```

2. Validation checks:
   - Machine configuration
   - Network settings
   - Cluster configuration
   - Certificate settings

You can also manually validate any config file:
```bash
# Validate a single config file
talosctl validate -c config.yaml

# Validate with verbose output
talosctl validate -c config.yaml -v
```

### Reinstalling Nodes

To reinstall nodes with clean disks:

1. Set WIPE_DISK=true in docker-compose.yml:
   ```yaml
   environment:
     - WIPE_DISK=true
   ```

2. Restart the services:
   ```bash
   cd docker
   docker-compose up -d
   ```

3. After reinstall, set WIPE_DISK back to false to prevent accidental disk wiping.

## Security

- Base configurations and node settings in Git (no secrets)
- Secrets generated by talosctl at runtime
- Generated configs stored only on matchbox server
- Each node gets its own configuration with unique secrets
- All configs validated before deployment
