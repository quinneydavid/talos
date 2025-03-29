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
│   ├── network-config.template.yaml  # Template for network configuration
│   └── storage-class.yaml    # Storage class for Synology CSI
├── docker/                   # Docker configurations
│   ├── docker-compose.yml    # Docker Compose configuration
│   ├── .env                  # Environment variables with sensitive information
│   ├── .env.example          # Example environment variables file
│   ├── Dockerfile.matchbox   # HTTP server for Talos configs
│   └── Dockerfile.matchbox-tftp # TFTP server for PXE boot
└── scripts/                  # Utility scripts
    ├── generate-configs.sh   # Config generation script
    ├── create-cluster.sh     # Cluster creation script
    └── bootstrap-flux.sh     # Flux bootstrap script
```

## Configuration

### Network Configuration

The network configuration uses a template-based approach to protect sensitive information:

1. **Template File**: `configs/network-config.template.yaml` contains the structure with placeholders:

```yaml
# Global settings
global:
  # Any global settings that apply to all clusters

# Cluster configurations
clusters:
  prod:
    network:
      vip: "${PROD_VIP}"  # VIP for Kubernetes API
    cluster:
      name: "${PROD_NAME}"
      endpoint: "${PROD_ENDPOINT}"
      dns_domain: "${PROD_DNS_DOMAIN}"
      pod_subnet: "${PROD_POD_SUBNET}"
      service_subnet: "${PROD_SERVICE_SUBNET}"
    nodes:
      prodcp1:
        mac: "00:11:22:33:44:55"
        hostname: "prodcp1"
        type: "controlplane"
      prodworker1:
        mac: "00:11:22:33:44:66"
        hostname: "prodworker1"
        type: "worker"
```

2. **Environment Variables**: The actual values are stored in the `.env` file:

```
# Prod Cluster Configuration (sensitive information)
PROD_VIP=192.168.1.100
PROD_NAME=cluster.example.com
PROD_ENDPOINT=https://api.cluster.example.com:6443
PROD_DNS_DOMAIN=cluster.local
PROD_POD_SUBNET=10.244.0.0/16
PROD_SERVICE_SUBNET=10.96.0.0/12
```

3. **Runtime Processing**: When the container starts, it:
   - Downloads the template from GitHub
   - Replaces the placeholders with values from the environment variables
   - Generates the actual configuration file

### DHCP Server Configuration

The external DHCP server must be configured with the following PXE boot parameters:

- filename: "lpxelinux.0"
- next-server: [IP address of your TFTP server]

The TFTP server will automatically generate the appropriate PXE boot configuration based on the node's MAC address.

### Environment Variables

The cluster configuration is controlled through environment variables in the `.env` file:

```
# GitHub Repository
GITHUB_REPO=https://github.com/yourusername/talos

# Configuration Options
FORCE_REGENERATE=false  # Set to true to force regeneration of existing configs

# Prod Cluster Configuration (sensitive information)
PROD_VIP=192.168.1.100
PROD_NAME=cluster.example.com
PROD_ENDPOINT=https://api.cluster.example.com:6443
PROD_DNS_DOMAIN=cluster.local
PROD_POD_SUBNET=10.244.0.0/16
PROD_SERVICE_SUBNET=10.96.0.0/12

# Talos Configuration
TALOS_VERSION=https://pxe.factory.talos.dev/pxe/latest/metal-amd64
WIPE_DISK=true  # Set to true to wipe disks during reinstall

# Network Configuration
MATCHBOX_HOST=matchbox.lan
```

The `.env` file is excluded from git to protect sensitive information. An `.env.example` file is provided as a template.

### Adding Nodes

To add more nodes to the cluster:

1. Add the node configuration to network-config.template.yaml:
   ```yaml
   clusters:
     prod:
       nodes:
         prodworker3:
           mac: "00:11:22:33:44:77"
           hostname: "prodworker3"
           type: "worker"
   ```

2. Commit and push the changes to GitHub:
   ```bash
   git add configs/network-config.template.yaml
   git commit -m "Add new worker node"
   git push
   ```

3. Restart the services:
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
2. Storage IPs are in the 10.10.10.0/24 network:
   - Control plane nodes: 10.10.10.10-12
   - Worker nodes: 10.10.10.13+
   - Synology NAS: 10.10.10.2

The storage class configuration is defined in `configs/storage-class.yaml`:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: synology-csi
provisioner: csi.synology.com
parameters:
  fsType: ext4
  location: "10.10.10.2"  # Synology NAS IP on storage network
  storage_pool: "volume1"
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

## Usage

### Initial Installation

1. Configure environment variables in docker-compose.yml
2. Start the services:
   ```bash
   cd docker
   docker-compose up -d
   ```
3. Create the cluster using the create-cluster.sh script:
   ```bash
   # For just cluster creation:
   ./scripts/create-cluster.sh

   # For cluster creation with Flux bootstrapping:
   ./scripts/create-cluster.sh --with-flux
   ```

The create-cluster.sh script will:
- Get talosconfig from the matchbox container
- Wait for all nodes to be ready
- Bootstrap the first control plane node
- Wait for Kubernetes to be ready
- Get kubeconfig for cluster access
- Optionally bootstrap Flux for GitOps management

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

1. Set WIPE_DISK=true in the `.env` file:
   ```
   # Talos Configuration
   TALOS_VERSION=https://pxe.factory.talos.dev/pxe/latest/metal-amd64
   WIPE_DISK=true  # Set to true to wipe disks during reinstall
   ```

2. Set FORCE_REGENERATE=true to regenerate all configurations:
   ```
   # Configuration Options
   FORCE_REGENERATE=true
   ```

3. Restart the services:
   ```bash
   cd docker
   docker-compose restart
   ```

4. After reinstall, set WIPE_DISK and FORCE_REGENERATE back to false to prevent accidental disk wiping and unnecessary regeneration.

## Talos Configuration Storage

### Configuration Generation and Storage Locations

Talos configurations are generated by the `generate-configs.sh` script and stored in specific locations:

1. **Matchbox Assets Directory**: `/var/lib/matchbox/assets/`
   - Final Talos configuration files for each node
   - Files are named according to node role and hostname (e.g., `controlplane-prodcp1.yaml`, `worker-prodworker1.yaml`)
   - The `talosconfig` file for API access is also stored here

2. **Temporary Directory**: `/tmp/talos/`
   - Used during the configuration generation process
   - Contains intermediate files that are created and then cleaned up

### Configuration Generation Process

The `generate-configs.sh` script performs these steps:

1. **Environment Setup**:
   - Verifies required environment variables (CLUSTER_NAME, CLUSTER_ENDPOINT, etc.)
   - These variables come from the Docker environment variables in `.env`

2. **Network Configuration**:
   - Reads node information from `/var/lib/matchbox/network-config.yaml`
   - This file defines nodes, roles, MAC addresses, and hostnames
   - The VIP (Virtual IP) for the control plane is also defined here

3. **Base Configuration Generation**:
   - Uses `talosctl gen config` to create base configurations for control plane and worker nodes
   - These are initially stored in the temporary directory

4. **Node-Specific Configuration**:
   - For each node defined in the network configuration:
     - Creates a network configuration patch specific to that node
     - Merges the base configuration with the node-specific patch
     - Validates the configuration
     - Stores the final configuration in the matchbox assets directory

5. **Talosconfig Generation**:
   - Updates the talosconfig file with control plane endpoints
   - Copies the final talosconfig to the matchbox assets directory

### Configuration Access During Boot

When nodes boot via PXE:

1. The TFTP server provides the initial boot files (kernel and initramfs)
2. The PXE configuration instructs the node to fetch its Talos configuration from the matchbox HTTP server
3. The node uses its MAC address to determine which configuration to load
4. The matchbox server serves the appropriate configuration file based on the node's identity

### Configuration Retrieval for Management

The `create-cluster.sh` script retrieves the talosconfig from the matchbox container:

```bash
docker cp docker_matchbox_1:/var/lib/matchbox/assets/talosconfig talos/tmp/talosconfig
```

This talosconfig file is then used to:
- Bootstrap the Talos cluster
- Generate a kubeconfig for Kubernetes access
- Manage the cluster nodes

### Integration with Terraform

The Talos VM management in Terraform uses the same node information:
- VM specifications defined in `nodes.yaml` 
- The same node information (hostnames, MAC addresses, roles) is used in both Terraform and Talos configuration
- This ensures consistency between the VM infrastructure and the Talos configuration

## Security

- **Template-Based Configuration**: 
  - Network configuration template stored in Git (no secrets)
  - Sensitive information stored in `.env` file (excluded from Git)
  - Template processed at runtime to generate actual configuration

- **Multi-Cluster Support**:
  - Each cluster has its own configuration section
  - Cluster-specific environment variables with prefix (e.g., PROD_*)
  - Support for multiple clusters in a single deployment

- **Configuration Protection**:
  - Existing configurations preserved unless FORCE_REGENERATE=true
  - Secrets generated by talosctl at runtime
  - Generated configs stored only on HTTP server
  - Each node gets its own configuration with unique secrets
  - All configs validated before deployment

- **Secure Boot Process**:
  - PXE boot configurations generated automatically based on MAC addresses
  - Each node receives only its own configuration
  - Configurations are validated before use
