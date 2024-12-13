# Talos Cluster Configuration

This repository contains the configuration for a Talos-based Kubernetes cluster using PXE boot with Matchbox.

## Overview

The system uses a simple, secure approach to manage Talos configurations:

- Base configurations stored in Git (no secrets)
- Node-specific settings in matchbox group files
- Configurations with secrets generated at runtime
- Automatic validation of generated configs
- Dynamic node discovery and configuration

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
│   │   ├── cp*.json         # Control plane nodes (cp1.json, cp2.json, etc.)
│   │   └── worker*.json     # Worker nodes (worker1.json, worker2.json, etc.)
│   └── profiles/            # Boot profiles
└── scripts/                  # Utility scripts
    └── generate-configs.sh   # Config generation script

## Configuration

### Environment Variables

The cluster configuration is controlled through environment variables in docker-compose.yml:

```yaml
environment:
  # Cluster Settings
  - CLUSTER_NAME=k8s.lan
  - CLUSTER_ENDPOINT=https://api.k8s.lan:6443
  - CLUSTER_DNS_DOMAIN=cluster.local
  - CLUSTER_POD_SUBNET=10.244.0.0/16
  - CLUSTER_SERVICE_SUBNET=10.96.0.0/12
  
  # Installation Options
  - WIPE_DISK=false  # Set to true to wipe disks during reinstall
  
  # Version Control
  - TALOS_VERSION=latest  # Use 'latest' or specific version like 'v1.5.5'
```

### Node Configuration

Nodes are automatically discovered from json files in `matchbox/groups/`:
- Control plane nodes: `cp*.json` (e.g., cp1.json, cp2.json, cp3.json)
- Worker nodes: `worker*.json` (e.g., worker1.json, worker2.json)

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

### Adding Nodes

To add more nodes to the cluster:

1. Create a new group file in `matchbox/groups/`:
   - Control plane: `cp<number>.json` (e.g., cp4.json)
   - Worker: `worker<number>.json` (e.g., worker3.json)

2. Configure the node settings:
   ```json
   {
       "id": "worker3",
       "name": "Worker Node 3",
       "profile": "worker",
       "selector": {
         "mac": "<node-mac-address>"
       },
       "metadata": {
         "ip": "192.168.86.216",
         "gateway": "192.168.86.1",
         "netmask": "255.255.255.0",
         "storage_ip": "10.44.5.22",
         "hostname": "worker3",
         "nameservers": ["192.168.86.2", "192.168.86.4"]
       }
   }
   ```

3. Commit and push the new group file
4. Restart the matchbox service:
   ```bash
   cd docker
   docker-compose restart matchbox
   ```

The system will automatically:
- Discover the new node configuration
- Generate appropriate Talos configs
- Make them available for PXE boot

### Storage Configuration

The cluster uses a dedicated storage network for Synology CSI:

1. Each node has a storage network interface (eth1) configured via group files
2. Storage IPs are in the 10.44.5.0/24 network:
   - Control plane nodes: 10.44.5.10-12
   - Worker nodes: 10.44.5.20+
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

### Version Management

The TALOS_VERSION environment variable controls which version of Talos to use:

1. Use latest version:
   ```yaml
   environment:
     - TALOS_VERSION=latest
   ```

2. Use specific version:
   ```yaml
   environment:
     - TALOS_VERSION=v1.5.5
   ```

3. Change version without rebuilding:
   ```bash
   # Update version in docker-compose.yml
   docker-compose up -d  # Container will download new version on restart
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
