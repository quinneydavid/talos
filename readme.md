# Talos Kubernetes Lab PXE Boot Setup

This repository contains the necessary configurations and Docker setup to PXE boot a Talos Kubernetes cluster using Matchbox.

## Architecture

- 3 Control Plane Nodes (192.168.86.211-213)
- 2 Worker Nodes (192.168.86.214-215)
- Virtual IP for HA: 192.168.86.241
- Storage Network: 10.44.5.0/24
- DNS Servers: 192.168.86.2, 192.168.86.4

## Prerequisites

- Docker and Docker Compose installed
- DHCP server configured to point to your PXE server
- Network infrastructure supporting PXE boot
- Physical or virtual machines with known MAC addresses

## Quick Start

1. Clone this repository:
```bash
git clone https://github.com/yourusername/talos-lab
cd talos-lab