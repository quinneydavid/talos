#!/bin/sh

# Script to install and configure SOPS (Secrets OPerationS)
# This script installs SOPS and sets up GPG for encryption

set -e

# Install SOPS if not present
if ! command -v sops >/dev/null 2>&1; then
    echo "Installing SOPS..."
    SOPS_VERSION=$(curl -s https://api.github.com/repos/mozilla/sops/releases/latest | jq -r .tag_name)
    curl -Lo sops "https://github.com/mozilla/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64"
    chmod +x sops
    sudo mv sops /usr/local/bin/
fi

# Check if GPG key exists
if ! gpg --list-secret-keys | grep -q "Talos Secrets"; then
    echo "Generating GPG key for SOPS..."
    # Generate GPG key
    cat >key-config <<EOF
%echo Generating GPG key for Talos Secrets
Key-Type: RSA
Key-Length: 4096
Name-Real: Talos Secrets
Name-Email: talos@local
Expire-Date: 0
%no-protection
%commit
EOF

    # Generate key
    gpg --batch --generate-key key-config
    rm key-config

    # Export public key
    gpg --export -a "Talos Secrets" > talos-secrets.pub.asc
    
    # Get key fingerprint
    KEY_FP=$(gpg --list-secret-keys "Talos Secrets" | grep -A1 "sec" | tail -n1 | awk '{print $1}')
    
    # Create .sops.yaml if it doesn't exist
    if [ ! -f .sops.yaml ]; then
        cat >.sops.yaml <<EOF
creation_rules:
  - path_regex: \.enc\.yaml$
    encrypted_regex: ^(data|stringData)$
    pgp: ${KEY_FP}
EOF
    fi
    
    echo "SOPS setup complete!"
    echo "Public key exported to talos-secrets.pub.asc"
    echo "SOPS configuration written to .sops.yaml"
else
    echo "GPG key for Talos Secrets already exists"
fi
