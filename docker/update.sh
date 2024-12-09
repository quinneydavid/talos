#!/bin/bash

# Directory where your docker-compose file is located
cd /path/to/talos-pxe

# Pull latest changes if using git
git pull

# Rebuild and restart containers
docker-compose build --no-cache
docker-compose up -d

# Log the update
echo "Updated at $(date)" >> update.log