#!/bin/bash
set -e

echo "Starting uninstallation of Docker, kubectl, and kind..."

# ----------------------------------------------------------
# 1. Stop and remove Docker
# ----------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
    echo "Stopping Docker service..."
    sudo systemctl stop docker || true
    sudo systemctl disable docker || true

    echo "Removing Docker packages..."
    sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
    sudo apt-get autoremove -y

    echo "Removing Docker data and configs..."
    sudo rm -rf /var/lib/docker
    sudo rm -rf /var/lib/containerd

    echo "Removing user from docker group..."
    sudo gpasswd -d $USER docker || true
else
    echo "Docker is not installed."
fi

# ----------------------------------------------------------
# 2. Remove kubectl
# ----------------------------------------------------------
if command -v kubectl >/dev/null 2>&1; then
    echo "Removing kubectl..."
    sudo rm -f /usr/local/bin/kubectl
else
    echo "kubectl is not installed."
fi

# ----------------------------------------------------------
# 3. Remove kind
# ----------------------------------------------------------
if command -v kind >/dev/null 2>&1; then
    echo "Removing kind..."
    sudo rm -f /usr/local/bin/kind
else
    echo "kind is not installed."
fi

echo "Uninstallation completed!"
echo "Note: If you were added to the docker group, log out and log back in to fully remove permissions."

