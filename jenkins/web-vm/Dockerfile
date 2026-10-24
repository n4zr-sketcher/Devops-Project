FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    nginx \
    sudo \
    curl \
    rsync \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Setup azureuser with passwordless sudo (matches the Azure VM user)
RUN useradd -m -s /bin/bash azureuser && \
    echo "azureuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Configure SSH
RUN mkdir -p /var/run/sshd /home/azureuser/.ssh && \
    chmod 700 /home/azureuser/.ssh

COPY authorized_keys /home/azureuser/.ssh/authorized_keys
RUN chmod 600 /home/azureuser/.ssh/authorized_keys && \
    chown -R azureuser:azureuser /home/azureuser/.ssh

# Generate fixed ed25519 host key at build time so it is persistent across container restarts
RUN ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -C "web-vm"

# Configure systemctl shim for deploy.sh
COPY systemctl-shim.sh /usr/local/bin/systemctl
RUN chmod +x /usr/local/bin/systemctl && cp /usr/local/bin/systemctl /bin/systemctl

# Setup initial Nginx configuration (matches cloud-init.yml.tftpl)
RUN mkdir -p /var/www/app /var/www/releases && \
    rm -f /etc/nginx/sites-enabled/default

RUN echo 'server {\n\
    listen 80 default_server;\n\
    listen [::]:80 default_server;\n\
    server_name _;\n\
\n\
    root /var/www/app;\n\
    index index.html;\n\
\n\
    location / {\n\
        try_files $uri $uri/ =404;\n\
    }\n\
\n\
    location = /health {\n\
        access_log off;\n\
        add_header Content-Type text/plain always;\n\
        return 200 "ok";\n\
    }\n\
\n\
    location = /build-info.txt {\n\
        add_header Cache-Control "no-store" always;\n\
    }\n\
}' > /etc/nginx/sites-available/app && \
    ln -sfn /etc/nginx/sites-available/app /etc/nginx/sites-enabled/app

# Initial placeholder page before first Jenkins deployment
RUN echo '<!doctype html><html lang="en"><head><meta charset="utf-8"/><title>Docker VM Bootstrap Complete</title><style>body{font-family:sans-serif;background:#0f172a;color:#e2e8f0;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;}.card{background:#1e293b;border:1px solid #334155;border-radius:16px;padding:48px;text-align:center;}h1{margin-bottom:12px;}.ok{color:#4ade80;font-weight:600;}</style></head><body><div class="card"><h1>Docker Ubuntu 22.04 VM Ready</h1><p class="ok">Nginx is running & waiting for first Jenkins deployment.</p><p>Health check: <code>/health</code></p></div></body></html>' > /var/www/app/index.html && \
    chown -R www-data:www-data /var/www && \
    chmod -R 755 /var/www/app

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
