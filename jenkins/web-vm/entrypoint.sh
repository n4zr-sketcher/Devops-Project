#!/usr/bin/env bash
set -e

# Ensure SSH host keys exist
ssh-keygen -A 2>/dev/null || true

# Start SSH daemon
service ssh start

echo "[web-vm] Starting Nginx on port 80..."
HOST_KEY=$(cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | cut -d' ' -f1,2 || true)
if [ -n "${HOST_KEY}" ]; then
    echo "=========================================================="
    echo " [web-vm] Known hosts entry for Jenkins credential:"
    echo " web-vm ${HOST_KEY}"
    echo "=========================================================="
fi
# Start Nginx in foreground
exec nginx -g "daemon off;"
