#!/bin/bash

# Check if age key file exists
if [ ! -f "$HOME/.config/sops/age/keys.txt" ]; then
    echo "Error: SOPS age key not found at $HOME/.config/sops/age/keys.txt"
    echo "Please ensure your age private key is stored there"
    exit 1
fi

# Bootstrap Flux onto the cluster
flux bootstrap github \
  --owner=quinneydavid \
  --repository=talos \
  --branch=main \
  --path=clusters/homelab \
  --personal \
  --components-extra=image-reflector-controller,image-automation-controller

# Create SOPS secret for Flux
kubectl -n flux-system create secret generic sops-age \
    --from-file=age.agekey=$HOME/.config/sops/age/keys.txt

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
  decryption:
    provider: sops
    secretRef:
      name: sops-age
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
  decryption:
    provider: sops
    secretRef:
      name: sops-age
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
  decryption:
    provider: sops
    secretRef:
      name: sops-age
EOF

echo "Flux bootstrap complete. Directory structure created:"
echo "clusters/homelab/"
echo "├── infrastructure/  # Core infrastructure (kube-vip, etc.)"
echo "├── apps/           # Applications"
echo "└── config/         # Cluster-wide configurations"

echo ""
echo "SOPS Setup:"
echo "1. Store your age private key at: $HOME/.config/sops/age/keys.txt"
echo "2. The key has been added to the cluster as a Kubernetes secret"
echo "3. Flux will use this key to decrypt secrets in the repository"
