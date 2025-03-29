# Talos Docker Compose Setup

This directory contains the Docker Compose configuration for bootstrapping a Talos Kubernetes cluster using PXE boot.

## Environment Variables

The Docker Compose setup uses environment variables to configure the Talos cluster. These variables can be set in a `.env` file in this directory. A sample `.env.example` file is provided as a template.

### Setting Up Environment Variables

1. Copy the example file to create your own `.env` file:
   ```bash
   cp .env.example .env
   ```

2. Edit the `.env` file to set your specific values:
   ```bash
   # Update with your actual values
   CLUSTER_NAME=prod.quinney.cloud
   CLUSTER_ENDPOINT=https://api.prod.quinney.cloud:6443
   # ... other variables
   ```

### Available Environment Variables

| Variable | Description | Default Value |
|----------|-------------|---------------|
| `GITHUB_REPO` | GitHub repository for network config | https://github.com/yourusername/talos |
| `CLUSTER_NAME` | Kubernetes cluster name | your-cluster-domain |
| `CLUSTER_ENDPOINT` | Kubernetes API endpoint | https://api.your-cluster-domain:6443 |
| `CLUSTER_DNS_DOMAIN` | Kubernetes DNS domain | cluster.local |
| `CLUSTER_POD_SUBNET` | Kubernetes pod subnet | 10.244.0.0/16 |
| `CLUSTER_SERVICE_SUBNET` | Kubernetes service subnet | 10.96.0.0/12 |
| `TALOS_VERSION` | Talos version to use | https://pxe.factory.talos.dev/pxe/... |
| `WIPE_DISK` | Whether to wipe disks during install | true |
| `CONTROL_PLANE_VIP` | VIP for the control plane | 10.88.8.210 |
| `MATCHBOX_HOST` | Hostname for the matchbox server | matchbox.lan |

## DNS Configuration

Before starting the Docker Compose setup, ensure your DNS is properly configured:

1. Set up DNS entries for:
   - `api.your-cluster-domain` → `CONTROL_PLANE_VIP`
   - `matchbox.lan` → IP of the host running the matchbox container
   - Optionally, a wildcard entry `*.your-cluster-domain` → `CONTROL_PLANE_VIP`

## Starting the Services

To start the services:

```bash
docker-compose up -d
```

This will start the matchbox and matchbox-tftp services, which will:
1. Download the Talos kernel and initramfs
2. Generate Talos configurations for each node
3. Set up TFTP for PXE booting

## Security Note

The `.env` file contains sensitive information and is excluded from git in the `.gitignore` file. Do not commit this file to your repository.
