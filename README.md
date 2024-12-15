# Talos Cluster Configuration

[Previous content remains the same until GitOps Configuration section]

## GitOps Configuration

The cluster uses Flux for GitOps-based configuration management. The structure is organized as follows:

### Infrastructure
Core cluster components:
- kube-vip: Deployed during cluster bootstrap via generate-configs.sh
- Additional infrastructure components can be added here and will be managed by Flux

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

## Component Deployment Strategy

### Bootstrap Components
Some critical components are deployed during cluster bootstrap:

1. kube-vip (configs/kube-vip.yaml):
   - Deployed via generate-configs.sh as an inline manifest
   - Provides immediate load balancing for control plane
   - Not managed by Flux to ensure availability during bootstrap

### GitOps-Managed Components
Additional components should be added through the GitOps structure:

1. Infrastructure (clusters/homelab/infrastructure/):
   - Add new infrastructure components here
   - Managed and reconciled by Flux
   - Deployed after cluster and Flux bootstrap

2. Applications (clusters/homelab/apps/):
   - Application workloads
   - Deployed after infrastructure is ready

[Rest of the existing content remains the same]
