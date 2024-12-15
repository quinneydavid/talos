#!/bin/bash

# Bootstrap Flux onto the cluster
flux bootstrap github \
  --owner=quinneydavid \
  --repository=talos \
  --branch=main \
  --path=clusters/homelab \
  --personal \
  --components-extra=image-reflector-controller,image-automation-controller

# Create the Flux Kustomizations for different components
cat <<EOF | kubectl apply -f -
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 10m
  path: ./clusters/homelab/infrastructure
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 10m
  path: ./clusters/homelab/apps
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: infrastructure
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: config
  namespace: flux-system
spec:
  interval: 10m
  path: ./clusters/homelab/config
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: infrastructure
EOF

echo "Flux bootstrap complete. Directory structure created:"
echo "clusters/homelab/"
echo "├── infrastructure/  # Core infrastructure (kube-vip, etc.)"
echo "├── apps/           # Applications"
echo "└── config/         # Cluster-wide configurations"
