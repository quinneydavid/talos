#!/bin/bash

# Script to install and configure SOPS (Secrets OPerationS) with age encryption
set -e

# Install SOPS if not present
if ! command -v sops >/dev/null 2>&1; then
    echo "Installing SOPS..."
    SOPS_VERSION=$(curl -s https://api.github.com/repos/mozilla/sops/releases/latest | jq -r .tag_name)
    curl -Lo sops "https://github.com/mozilla/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64"
    chmod +x sops
    sudo mv sops /usr/local/bin/
fi

# Install age if not present
if ! command -v age-keygen >/dev/null 2>&1; then
    echo "Installing age..."
    AGE_VERSION=$(curl -s https://api.github.com/repos/FiloSottile/age/releases/latest | jq -r .tag_name)
    curl -Lo age.tar.gz "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz"
    tar xf age.tar.gz
    sudo mv age/age* /usr/local/bin/
    rm -rf age age.tar.gz
fi

# Setup age key directory
AGE_KEY_DIR="$HOME/.config/sops/age"
mkdir -p "$AGE_KEY_DIR"

# Generate age key if it doesn't exist
if [ ! -f "$AGE_KEY_DIR/keys.txt" ]; then
    echo "Generating new age key..."
    age-keygen -o "$AGE_KEY_DIR/keys.txt"
    
    # Extract public key
    PUBLIC_KEY=$(age-keygen -y "$AGE_KEY_DIR/keys.txt")
    
    # Create .sops.yaml
    cat >.sops.yaml <<EOF
creation_rules:
  - path_regex: .*.enc.yaml
    encrypted_regex: ^(data|stringData)$
    age: >-
      ${PUBLIC_KEY}
EOF
    
    echo "SOPS setup complete!"
    echo "Private key location: $AGE_KEY_DIR/keys.txt"
    echo "Public key: $PUBLIC_KEY"
    echo "SOPS configuration written to .sops.yaml"
    echo ""
    echo "IMPORTANT: Backup your private key ($AGE_KEY_DIR/keys.txt) securely!"
    echo "This key will be needed to decrypt secrets and should never be committed to git."
else
    echo "Age key already exists at $AGE_KEY_DIR/keys.txt"
    echo "Using existing key for SOPS configuration"
fi

# Instructions for Flux
echo ""
echo "To use with Flux:"
echo "1. The private key is stored at: $AGE_KEY_DIR/keys.txt"
echo "2. When running bootstrap-flux.sh, it will:"
echo "   - Create a Kubernetes secret with this key"
echo "   - Configure Flux to use it for decryption"
echo ""
echo "Note: Keep your private key safe and never commit it to git!"
