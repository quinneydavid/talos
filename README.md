# Talos Cluster Configuration

This repository contains the configuration for a Talos-based Kubernetes cluster using PXE boot with TFTP.

## Overview

The system uses a simple, secure approach to manage Talos configurations:

- Single network configuration file for all nodes
- Configurations with secrets generated at runtime
- Automatic validation of generated configs
- Dynamic node discovery and configuration via PXE boot

## Structure

```
.
├── configs/                    # Configuration files
│   ├── network-config.yaml    # Node and network configuration
│   └── storage-class.yaml     # Storage class for Synology CSI
├── docker/                    # Docker configurations
│   ├── docker-compose.yml     # Docker Compose configuration
│   ├── Dockerfile.matchbox    # HTTP server for Talos configs
│   └── Dockerfile.matchbox-tftp # TFTP server for PXE boot
└── scripts/                  # Utility scripts
    └── generate-configs.sh   # Config generation script
```

## Configuration

### Network Configuration

All node configurations are defined in a single YAML file (`configs/network-config.yaml`):

```yaml
# Global network settings
network:
  gateway: "192.168.86.1"
  netmask: "255.255.255.0"
  nameservers:
    - "192.168.86.2"
    - "192.168.86.4"

# Node-specific configurations
nodes:
  cp1:
    mac: "50:6b:8d:96:f7:50"
    ip: "192.168.86.211"
    storage_ip: "10.44.5.10"
    hostname: "cp1"
    type: "controlplane"

  worker1:
    mac: "50:6b:8d:ff:7b:7e"
    ip: "192.168.86.214"
    storage_ip: "10.44.5.13"
    hostname: "worker1"
    type: "worker"
```

### DHCP Server Configuration

The external DHCP server must be configured with the following PXE boot parameters:

- filename: "lpxelinux.0"
- next-server: [IP address of your TFTP server]

The TFTP server will automatically generate the appropriate PXE boot configuration based on the node's MAC address.

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

### Adding Nodes

To add more nodes to the cluster:

1. Add the node configuration to network-config.yaml:
   ```yaml
   nodes:
     worker3:
       mac: "50:6b:8d:xx:xx:xx"
       ip: "192.168.86.216"
       storage_ip: "10.44.5.15"
       hostname: "worker3"
       type: "worker"
   ```

2. Restart the services:
   ```bash
   cd docker
   docker-compose restart
   ```

The system will automatically:
- Generate appropriate Talos configs
- Create PXE boot configurations
- Make them available for network boot

### Storage Configuration

The cluster uses a dedicated storage network for Synology CSI:

1. Each node has a storage network interface (eth1) configured via network-config.yaml
2. Storage IPs are in the 10.44.5.0/24 network:
   - Control plane nodes: 10.44.5.10-12
   - Worker nodes: 10.44.5.13+
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

- Node configuration stored in Git (no secrets)
- Secrets generated by talosctl at runtime
- Generated configs stored only on HTTP server
- Each node gets its own configuration with unique secrets
- All configs validated before deployment
- PXE boot configurations generated automatically based on MAC addresses
