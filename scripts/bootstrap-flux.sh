#!/bin/bash

# Install or update Flux CLI
echo "Installing/updating Flux CLI..."
curl -s https://fluxcd.io/install.sh | sudo bash

# Check if age key file exists
if [ ! -f "$HOME/.config/sops/age/keys.txt" ]; then
    echo "Error: SOPS age key not found at $HOME/.config/sops/age/keys.txt"
    echo "Please ensure your age private key is stored there"
    exit 1
fi

# Uninstall any existing Flux installation
echo "Cleaning up any existing Flux installation..."
flux uninstall --silent || true

# Install Flux components
echo "Installing Flux components..."
flux install \
  --components-extra=image-reflector-controller,image-automation-controller \
  --network-policy=false \
  --timeout=5m

# Wait for Flux CRDs to be ready
echo "Waiting for Flux CRDs to be ready..."
kubectl wait --for=condition=established --timeout=60s crd/gitrepositories.source.toolkit.fluxcd.io || true
kubectl wait --for=condition=established --timeout=60s crd/kustomizations.kustomize.toolkit.fluxcd.io || true

# Bootstrap Flux onto the cluster
echo "Bootstrapping Flux onto the cluster..."
flux bootstrap github \
  --owner=quinneydavid \
  --repository=talos \
  --branch=main \
  --path=clusters/homelab \
  --personal \
  --token-auth \
  --components-extra=image-reflector-controller,image-automation-controller \
  --timeout=5m

# Wait for flux-system namespace
echo "Waiting for flux-system namespace..."
kubectl wait --for=condition=established --timeout=60s namespace/flux-system || true

# Create SOPS secret for Flux
echo "Creating SOPS secret..."
kubectl -n flux-system create secret generic sops-age \
    --from-file=age.agekey=$HOME/.config/sops/age/keys.txt

# Create the Flux Kustomizations for different components
echo "Creating Flux Kustomizations..."
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
echo "├── infrastructure/  # Core infrastructure (kube-vip etc.)"
echo "├── apps/           # Applications"
echo "└── config/         # Cluster-wide configurations"

echo ""
echo "SOPS Setup:"
echo "1. Store your age private key at: $HOME/.config/sops/age/keys.txt"
echo "2. The key has been added to the cluster as a Kubernetes secret"
echo "3. Flux will use this key to decrypt secrets in the repository"
