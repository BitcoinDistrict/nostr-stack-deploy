#!/usr/bin/env bash
set -euo pipefail

# Normalize boolean-like envs (true/1/yes/on)
to_bool() {
    case "${1:-}" in
        [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Yy]|[Oo][Nn]) return 0 ;;
        *) return 1 ;;
    esac
}

# -----------------------------
# Paths
# -----------------------------
REPO_DIR="$HOME/nostr-stack-deploy"
STRFRY_DIR="$REPO_DIR/strfry"
CONFIG_DIR="$REPO_DIR/configs"
RUNTIME_CONFIG_DIR="$HOME/.strfry"
DATA_DIR="$HOME/nostr-stack-deploy/strfry-db"

# -----------------------------
# Configurable params (env-overridable)
# -----------------------------
# Domain for the relay (e.g., relay.example.com)
DOMAIN="${DOMAIN:-relay.bitcoindistrict.org}"
# Email for Let's Encrypt/Certbot registration
CERTBOT_EMAIL="${CERTBOT_EMAIL:-hey@bitcoindistrict.org}"
# Enable Cloudflare DNS validation for ACME (set to "true" to enable)
CLOUDFLARE_ENABLED="${CLOUDFLARE_ENABLED:-false}"
# Cloudflare API token with DNS edit permissions for the zone
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"

# Optional dashboard deployment
DASHBOARD_ENABLED="${DASHBOARD_ENABLED:-false}"
DASHBOARD_DOMAIN="${DASHBOARD_DOMAIN:-dashboard.relay.bitcoindistrict.org}"

# Optional Blossom media server deployment
BLOSSOM_ENABLED="${BLOSSOM_ENABLED:-false}"
BLOSSOM_DOMAIN="${BLOSSOM_DOMAIN:-media.${DOMAIN}}"
BLOSSOM_CONTAINER_IMAGE="${BLOSSOM_CONTAINER_IMAGE:-ghcr.io/hzrd149/blossom-server:master}"
BLOSSOM_PORT="${BLOSSOM_PORT:-3300}"
BLOSSOM_MAX_UPLOAD_MB="${BLOSSOM_MAX_UPLOAD_MB:-16}"
BLOSSOM_GATE_MODE="${BLOSSOM_GATE_MODE:-nip05}"
BLOSSOM_ALLOWLIST_FILE="${BLOSSOM_ALLOWLIST_FILE:-}"
NOSTR_AUTH_ENABLED="${NOSTR_AUTH_ENABLED:-true}"
NOSTR_AUTH_PORT="${NOSTR_AUTH_PORT:-3310}"
NOSTR_AUTH_GATE_MODE="${NOSTR_AUTH_GATE_MODE:-nip05}"
NOSTR_AUTH_ALLOWLIST_FILE="${NOSTR_AUTH_ALLOWLIST_FILE:-}"
NOSTR_AUTH_CACHE_TTL_SECONDS="${NOSTR_AUTH_CACHE_TTL_SECONDS:-300}"
NOSTR_AUTH_LOG_LEVEL="${NOSTR_AUTH_LOG_LEVEL:-info}"

# -----------------------------
# Install build dependencies
# -----------------------------
sudo apt-get update -y
sudo apt-get install -y build-essential libsqlite3-dev libssl-dev pkg-config \
    liblmdb-dev libflatbuffers-dev libsecp256k1-dev libzstd-dev zlib1g-dev

# -----------------------------
# Install and configure nginx
# -----------------------------
echo "🌐 Installing and configuring nginx..."
echo "Config summary:"
echo "  DOMAIN=${DOMAIN}"
echo "  DASHBOARD_ENABLED=${DASHBOARD_ENABLED}"
echo "  DASHBOARD_DOMAIN=${DASHBOARD_DOMAIN}"
echo "  BLOSSOM_ENABLED=${BLOSSOM_ENABLED}"
echo "  BLOSSOM_DOMAIN=${BLOSSOM_DOMAIN}"
echo "  BLOSSOM_PORT=${BLOSSOM_PORT}"
echo "  BLOSSOM_MAX_UPLOAD_MB=${BLOSSOM_MAX_UPLOAD_MB}"
echo "  NOSTR_AUTH_ENABLED=${NOSTR_AUTH_ENABLED}"
echo "  NOSTR_AUTH_PORT=${NOSTR_AUTH_PORT}"
sudo apt-get install -y nginx certbot python3-certbot-nginx python3-certbot-dns-cloudflare jq

# Ensure firewall allows HTTP/HTTPS early for ACME challenges
if command -v ufw >/dev/null 2>&1; then
    sudo ufw --force enable || true
    sudo ufw allow 'Nginx Full' || true
else
    sudo apt-get install -y ufw
    sudo ufw --force enable || true
    sudo ufw allow 'Nginx Full' || true
fi

# Prepare an initial HTTP-only config to serve the domain prior to certificate issuance
NGINX_SITE_PATH="/etc/nginx/sites-available/${DOMAIN}"
cat << 'EOF' | sudo tee "${NGINX_SITE_PATH}" >/dev/null
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# Prefer Cloudflare's client IP if present, otherwise use remote_addr
map $http_cf_connecting_ip $client_ip {
    default $http_cf_connecting_ip;
    ''      $remote_addr;
}

upstream strfry_ws {
    server 127.0.0.1:7777;
}

server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;

    # Allow ACME HTTP-01 if needed
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://strfry_ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $client_ip;
        proxy_set_header X-Forwarded-For $client_ip;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

# Replace placeholder domain
sudo sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" "${NGINX_SITE_PATH}"

# Enable the site and ensure webroot exists
sudo ln -sf "${NGINX_SITE_PATH}" "/etc/nginx/sites-enabled/${DOMAIN}"
sudo mkdir -p /var/www/certbot

# Test and reload nginx
sudo nginx -t
sudo systemctl reload nginx

echo "✅ Nginx HTTP config enabled for ${DOMAIN}"

# -----------------------------
# Configure SSL certificate for Cloudflare Full Strict mode
# -----------------------------
echo "🔒 Obtaining Let's Encrypt certificate for ${DOMAIN}..."
CERT_STATUS="failed"
if [ "$CLOUDFLARE_ENABLED" = "true" ] && [ -n "$CLOUDFLARE_API_TOKEN" ]; then
    echo "   Using Cloudflare DNS-01 challenge (suitable for proxied orange-cloud records)"
    CLOUDFLARE_INI="/etc/letsencrypt/cloudflare.ini"
    sudo mkdir -p "/etc/letsencrypt"
    echo "dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}" | sudo tee "$CLOUDFLARE_INI" >/dev/null
    sudo chmod 600 "$CLOUDFLARE_INI"

    if sudo certbot certonly \
            --dns-cloudflare \
            --dns-cloudflare-credentials "$CLOUDFLARE_INI" \
            --dns-cloudflare-propagation-seconds 60 \
            -d "$DOMAIN" \
            --non-interactive --agree-tos -m "$CERTBOT_EMAIL"; then
        echo "✅ Certificate obtained via Cloudflare DNS"
        CERT_STATUS="ok"
    else
        echo "❌ Failed to obtain certificate via Cloudflare DNS"
    fi
else
    echo "   Using Nginx HTTP-01 challenge (ensure DNS is pointing to this server; proxy can be orange or gray)"
    if sudo certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL"; then
        echo "✅ Certificate obtained via Nginx HTTP-01"
        CERT_STATUS="ok"
    else
        echo "❌ Failed to obtain certificate via Nginx HTTP-01"
    fi
fi

# -----------------------------
# Optional: Deploy static dashboard
# -----------------------------
if to_bool "$DASHBOARD_ENABLED"; then
    echo "📊 Installing dashboard (domain: ${DASHBOARD_DOMAIN})..."

    DASHBOARD_SITE_PATH="/etc/nginx/sites-available/${DASHBOARD_DOMAIN}"

    # HTTP-only vhost for ACME and initial serve
    cat << 'EOF' | sudo tee "${DASHBOARD_SITE_PATH}" >/dev/null
server {
    listen 80;
    server_name DASHBOARD_DOMAIN_PLACEHOLDER;

    root /var/www/relay-dashboard;
    index index.html;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
EOF
    sudo sed -i "s/DASHBOARD_DOMAIN_PLACEHOLDER/${DASHBOARD_DOMAIN}/g" "${DASHBOARD_SITE_PATH}"
    sudo ln -sf "${DASHBOARD_SITE_PATH}" "/etc/nginx/sites-enabled/${DASHBOARD_DOMAIN}"
    sudo mkdir -p /var/www/relay-dashboard
    sudo nginx -t && sudo systemctl reload nginx

    echo "🔒 Obtaining Let's Encrypt certificate for ${DASHBOARD_DOMAIN}..."
    DASH_CERT_STATUS="failed"
    if [ "$CLOUDFLARE_ENABLED" = "true" ] && [ -n "$CLOUDFLARE_API_TOKEN" ]; then
        CLOUDFLARE_INI="/etc/letsencrypt/cloudflare.ini"
        sudo mkdir -p "/etc/letsencrypt"
        echo "dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}" | sudo tee "$CLOUDFLARE_INI" >/dev/null
        sudo chmod 600 "$CLOUDFLARE_INI"
        if sudo certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials "$CLOUDFLARE_INI" \
                --dns-cloudflare-propagation-seconds 60 \
                -d "$DASHBOARD_DOMAIN" \
                --non-interactive --agree-tos -m "$CERTBOT_EMAIL"; then
            DASH_CERT_STATUS="ok"
        fi
    else
        if sudo certbot certonly --nginx -d "$DASHBOARD_DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL"; then
            DASH_CERT_STATUS="ok"
        fi
    fi

    if [ "$DASH_CERT_STATUS" = "ok" ] || [ -f "/etc/letsencrypt/live/${DASHBOARD_DOMAIN}/fullchain.pem" ]; then
        cat << 'EOF' | sudo tee "${DASHBOARD_SITE_PATH}" >/dev/null
server {
    listen 80;
    server_name DASHBOARD_DOMAIN_PLACEHOLDER;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name DASHBOARD_DOMAIN_PLACEHOLDER;

    ssl_certificate /etc/letsencrypt/live/DASHBOARD_DOMAIN_PLACEHOLDER/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/DASHBOARD_DOMAIN_PLACEHOLDER/privkey.pem;

    root /var/www/relay-dashboard;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
EOF
        sudo sed -i "s/DASHBOARD_DOMAIN_PLACEHOLDER/${DASHBOARD_DOMAIN}/g" "${DASHBOARD_SITE_PATH}"
        sudo nginx -t && sudo systemctl reload nginx
        echo "✅ Dashboard HTTPS config enabled for ${DASHBOARD_DOMAIN}"
    else
        echo "⚠️  Could not obtain HTTPS for dashboard; serving HTTP-only for now."
    fi

    # Install static assets and ensure writable by dashboard service user
    sudo mkdir -p /var/www/relay-dashboard
    sudo cp -r "$REPO_DIR/web/relay-dashboard/"* /var/www/relay-dashboard/
    sudo chown -R deploy:deploy /var/www/relay-dashboard

    # Install systemd units for initial webroot and stats generation
    sudo cp "$REPO_DIR/configs/dashboard/relay-dashboard.service" /etc/systemd/system/
    sudo cp "$REPO_DIR/configs/dashboard/relay-dashboard-stats.service" /etc/systemd/system/
    sudo cp "$REPO_DIR/configs/dashboard/relay-dashboard-stats.timer" /etc/systemd/system/

    # Write environment file with resolved paths
    sudo mkdir -p "$REPO_DIR/configs/dashboard"
    DASH_ENV_PATH="$REPO_DIR/configs/dashboard/dashboard.env"
    STRFRY_BIN_PATH="$STRFRY_DIR/strfry"
    NIP11_URL_VALUE="https://${DOMAIN}"
    STRFRY_CONFIG_VALUE="$RUNTIME_CONFIG_DIR/strfry.conf"
    # If dashboard.env exists, update only dynamic fields that depend on DOMAIN/paths
    if [ -f "$DASH_ENV_PATH" ]; then
        sudo sed -i "s|^STRFRY_BIN=.*$|STRFRY_BIN=${STRFRY_BIN_PATH}|" "$DASH_ENV_PATH"
        sudo sed -i "s|^DASHBOARD_ROOT=.*$|DASHBOARD_ROOT=/var/www/relay-dashboard|" "$DASH_ENV_PATH"
        if grep -q '^STRFRY_CONFIG=' "$DASH_ENV_PATH"; then
            sudo sed -i "s|^STRFRY_CONFIG=.*$|STRFRY_CONFIG=${STRFRY_CONFIG_VALUE}|" "$DASH_ENV_PATH"
        else
            echo "STRFRY_CONFIG=${STRFRY_CONFIG_VALUE}" | sudo tee -a "$DASH_ENV_PATH" >/dev/null
        fi
        sudo sed -i "s|^NIP11_URL=.*$|NIP11_URL=${NIP11_URL_VALUE}|" "$DASH_ENV_PATH"
    else
        cat <<EOF | sudo tee "$DASH_ENV_PATH" >/dev/null
STRFRY_BIN=${STRFRY_BIN_PATH}
DASHBOARD_ROOT=/var/www/relay-dashboard
STRFRY_CONFIG=${STRFRY_CONFIG_VALUE}
NIP11_URL=${NIP11_URL_VALUE}
EOF
    fi

    sudo systemctl daemon-reload
    sudo systemctl enable relay-dashboard.service
    sudo systemctl start relay-dashboard.service
    sudo systemctl enable relay-dashboard-stats.timer
    sudo systemctl start relay-dashboard-stats.timer
    # Generate stats and nip11 cache immediately for initial page load
    sudo systemctl start relay-dashboard-stats.service || true
    echo "✅ Dashboard installed"
else
    echo "ℹ️  Dashboard disabled (set DASHBOARD_ENABLED=true to enable)"
fi

# -----------------------------
# Optional: Deploy Blossom media server
# -----------------------------
if to_bool "$BLOSSOM_ENABLED"; then
    echo "🌸 Installing Blossom (domain: ${BLOSSOM_DOMAIN})..."

    # Ensure docker is installed for containerized services
    if ! command -v docker >/dev/null 2>&1; then
        echo "🐳 Installing Docker..."
        curl -fsSL https://get.docker.com | sudo sh
        sudo usermod -aG docker "$USER" || true
    fi

    # Prepare runtime directories and config
    sudo mkdir -p /var/lib/blossom /etc/blossom
    sudo chown -R deploy:deploy /var/lib/blossom || true
    # Write blossom config with resolved values
    sudo bash -c "cat > /etc/blossom/config.yml <<EOF
server:
  host: 127.0.0.1
  port: 3000
  base_url: https://${BLOSSOM_DOMAIN}

storage:
  data_dir: /var/lib/blossom

limits:
  max_upload_mb: ${BLOSSOM_MAX_UPLOAD_MB}
EOF"

    # Write default files for systemd env overrides
    sudo mkdir -p /etc/default
    sudo bash -c "cat > /etc/default/blossom <<EOF
BLOSSOM_CONTAINER_IMAGE=${BLOSSOM_CONTAINER_IMAGE}
BLOSSOM_PORT=${BLOSSOM_PORT}
EOF"
    sudo bash -c "cat > /etc/default/nostr-auth-proxy <<EOF
NOSTR_AUTH_PORT=${NOSTR_AUTH_PORT}
NOSTR_AUTH_GATE_MODE=${NOSTR_AUTH_GATE_MODE}
NOSTR_AUTH_CACHE_TTL_SECONDS=${NOSTR_AUTH_CACHE_TTL_SECONDS}
NOSTR_AUTH_LOG_LEVEL=${NOSTR_AUTH_LOG_LEVEL}
NOSTR_AUTH_ALLOWLIST_FILE=${NOSTR_AUTH_ALLOWLIST_FILE}
EOF"

    # Install systemd units (standalone auth proxy + blossom)
    sudo cp "$REPO_DIR/configs/auth/nostr-auth-proxy.service" /etc/systemd/system/nostr-auth-proxy.service
    sudo cp "$REPO_DIR/configs/blossom/blossom.service" /etc/systemd/system/blossom.service
    sudo systemctl daemon-reload

    # Build/start auth proxy first (needed for auth_request)
    if to_bool "$NOSTR_AUTH_ENABLED"; then
        sudo systemctl enable nostr-auth-proxy.service
        sudo systemctl restart nostr-auth-proxy.service
    fi

    # Start blossom server container via systemd
    sudo systemctl enable blossom.service
    sudo systemctl restart blossom.service

    # Create HTTP-only vhost for ACME
    BLOSSOM_SITE_PATH="/etc/nginx/sites-available/${BLOSSOM_DOMAIN}"
    cat << 'EOF' | sudo tee "${BLOSSOM_SITE_PATH}" >/dev/null
map $http_cf_connecting_ip $client_ip {
    default $http_cf_connecting_ip;
    ''      $remote_addr;
}

upstream blossom_upstream { server 127.0.0.1:BLOSSOM_PORT_PLACEHOLDER; }
upstream blossom_auth { server 127.0.0.1:NOSTR_AUTH_PORT_PLACEHOLDER; }

server {
    listen 80;
    server_name BLOSSOM_DOMAIN_PLACEHOLDER;
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Temporarily allow direct proxy for cert issuance
    location / {
        proxy_pass http://blossom_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $client_ip;
        proxy_set_header X-Forwarded-For $client_ip;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
    sudo sed -i "s/BLOSSOM_DOMAIN_PLACEHOLDER/${BLOSSOM_DOMAIN}/g" "${BLOSSOM_SITE_PATH}"
    sudo sed -i "s/BLOSSOM_PORT_PLACEHOLDER/${BLOSSOM_PORT}/g" "${BLOSSOM_SITE_PATH}"
    sudo sed -i "s/NOSTR_AUTH_PORT_PLACEHOLDER/${NOSTR_AUTH_PORT}/g" "${BLOSSOM_SITE_PATH}"
    sudo ln -sf "${BLOSSOM_SITE_PATH}" "/etc/nginx/sites-enabled/${BLOSSOM_DOMAIN}"
    sudo nginx -t && sudo systemctl reload nginx
    echo "📄 Wrote HTTP vhost for Blossom: ${BLOSSOM_SITE_PATH}"
    ls -l "/etc/nginx/sites-available/" | sed 's/^/  /'

    echo "🔒 Obtaining Let's Encrypt certificate for ${BLOSSOM_DOMAIN}..."
    BLOSSOM_CERT_STATUS="failed"
    if [ "$CLOUDFLARE_ENABLED" = "true" ] && [ -n "$CLOUDFLARE_API_TOKEN" ]; then
        CLOUDFLARE_INI="/etc/letsencrypt/cloudflare.ini"
        sudo mkdir -p "/etc/letsencrypt"
        echo "dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}" | sudo tee "$CLOUDFLARE_INI" >/dev/null
        sudo chmod 600 "$CLOUDFLARE_INI"
        if sudo certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials "$CLOUDFLARE_INI" \
                --dns-cloudflare-propagation-seconds 60 \
                -d "$BLOSSOM_DOMAIN" \
                --non-interactive --agree-tos -m "$CERTBOT_EMAIL"; then
            BLOSSOM_CERT_STATUS="ok"
        fi
    else
        if sudo certbot certonly --nginx -d "$BLOSSOM_DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL"; then
            BLOSSOM_CERT_STATUS="ok"
        fi
    fi

    if [ "$BLOSSOM_CERT_STATUS" = "ok" ] || [ -f "/etc/letsencrypt/live/${BLOSSOM_DOMAIN}/fullchain.pem" ]; then
        cat << 'EOF' | sudo tee "${BLOSSOM_SITE_PATH}" >/dev/null
map $http_cf_connecting_ip $client_ip {
    default $http_cf_connecting_ip;
    ''      $remote_addr;
}

upstream blossom_upstream { server 127.0.0.1:BLOSSOM_PORT_PLACEHOLDER; }
upstream blossom_auth { server 127.0.0.1:NOSTR_AUTH_PORT_PLACEHOLDER; }

server {
    listen 80;
    server_name BLOSSOM_DOMAIN_PLACEHOLDER;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name BLOSSOM_DOMAIN_PLACEHOLDER;

    ssl_certificate /etc/letsencrypt/live/BLOSSOM_DOMAIN_PLACEHOLDER/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/BLOSSOM_DOMAIN_PLACEHOLDER/privkey.pem;

    # Public read endpoints
    location / {
        proxy_pass http://blossom_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $client_ip;
        proxy_set_header X-Forwarded-For $client_ip;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size BLOSSOM_MAX_UPLOAD_MB_PLACEHOLDERm;
    }

    # Upload endpoints (protect with auth_request when gate enabled)
    location /upload {
        # Gate modes: nip05/allowlist -> require auth; open -> no auth
        auth_request /__auth;
        proxy_pass http://blossom_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $client_ip;
        proxy_set_header X-Forwarded-For $client_ip;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size BLOSSOM_MAX_UPLOAD_MB_PLACEHOLDERm;
    }

    location = /__auth {
        internal;
        proxy_pass http://blossom_auth/auth;
        proxy_set_header X-NIP05 $http_x_nip05;
        proxy_set_header Authorization $http_authorization;
        proxy_set_header X-Original-Host $host;
        proxy_set_header X-Original-URI $request_uri;
        proxy_set_header X-Original-Method $request_method;
        proxy_set_header X-Original-Scheme $scheme;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
    }
}
EOF
        sudo sed -i "s/BLOSSOM_DOMAIN_PLACEHOLDER/${BLOSSOM_DOMAIN}/g" "${BLOSSOM_SITE_PATH}"
        sudo sed -i "s/BLOSSOM_PORT_PLACEHOLDER/${BLOSSOM_PORT}/g" "${BLOSSOM_SITE_PATH}"
        sudo sed -i "s/NOSTR_AUTH_PORT_PLACEHOLDER/${NOSTR_AUTH_PORT}/g" "${BLOSSOM_SITE_PATH}"
        sudo sed -i "s/BLOSSOM_MAX_UPLOAD_MB_PLACEHOLDER/${BLOSSOM_MAX_UPLOAD_MB}/g" "${BLOSSOM_SITE_PATH}"

        # If gate is open, remove auth_request from the nginx conf
        if [ "$BLOSSOM_GATE_MODE" = "open" ]; then
            sudo sed -i "/auth_request \\/__auth;/d" "${BLOSSOM_SITE_PATH}"
        fi

        sudo nginx -t && sudo systemctl reload nginx
        echo "✅ Blossom HTTPS config enabled for ${BLOSSOM_DOMAIN}"
        echo "🔎 Nginx active sites:"
        ls -l /etc/nginx/sites-enabled | sed 's/^/  /'
    else
        echo "⚠️  Could not obtain HTTPS for Blossom; serving HTTP-only for now."
    fi

    echo "🔎 Systemd service statuses (post-start):"
    sudo systemctl --no-pager status blossom || true
    if [ "$NOSTR_AUTH_ENABLED" = "true" ]; then
        sudo systemctl --no-pager status nostr-auth-proxy || true
    fi
else
    echo "ℹ️  Blossom disabled (set BLOSSOM_ENABLED=true to enable)"
fi
if [ "$CERT_STATUS" = "ok" ] || [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    # Write final HTTPS-enabled config
    cat << 'EOF' | sudo tee "${NGINX_SITE_PATH}" >/dev/null
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# Prefer Cloudflare's client IP if present, otherwise use remote_addr
map $http_cf_connecting_ip $client_ip {
    default $http_cf_connecting_ip;
    ''      $remote_addr;
}

upstream strfry_ws {
    server 127.0.0.1:7777;
}

server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name DOMAIN_PLACEHOLDER;

    ssl_certificate /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/privkey.pem;

    location / {
        proxy_pass http://strfry_ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $client_ip;
        proxy_set_header X-Forwarded-For $client_ip;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
    sudo sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" "${NGINX_SITE_PATH}"

    sudo nginx -t
    sudo systemctl reload nginx

    echo "✅ Nginx HTTPS config enabled for ${DOMAIN}"
    echo "   If using Cloudflare, set SSL mode to 'Full (strict)'"
else
    echo "⚠️  Certificate not available; keeping HTTP-only config for now."
    echo "   You can re-run cert issuance later once DNS is ready."
fi

# -----------------------------
# Configure swap space for memory-constrained systems
# -----------------------------
if [ ! -f /swapfile ]; then
    echo "📦 Setting up swap space for memory-constrained compilation..."
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    
    # Make swap permanent
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    fi
    echo "✅ Swap space configured (2GB)"
else
    echo "✅ Swap space already exists"
fi

# -----------------------------
# Configure firewall
# -----------------------------
sudo ufw --force enable
sudo ufw allow ssh
sudo ufw allow 'Nginx Full'  # Allow HTTP (80) and HTTPS (443)
echo "✅ Firewall configured: SSH and Nginx (HTTP/HTTPS) allowed"

# -----------------------------
# Determine optimal compilation settings based on available memory
# -----------------------------
TOTAL_MEM=$(free -m | awk 'NR==2{printf "%.0f", $2}')
echo "💾 Total system memory: ${TOTAL_MEM}MB"

if [ "$TOTAL_MEM" -lt 2048 ]; then
    # Less than 2GB RAM - use single-threaded compilation
    MAKE_JOBS=1
    echo "🔧 Using single-threaded compilation (low memory system)"
else
    # 2GB+ RAM - use parallel compilation with conservative job count
    CPU_CORES=$(nproc)
    if [ "$TOTAL_MEM" -lt 4096 ]; then
        # 2-4GB RAM - use half the cores
        MAKE_JOBS=$((CPU_CORES / 2))
    else
        # 4GB+ RAM - use all cores
        MAKE_JOBS=$CPU_CORES
    fi
    echo "🔧 Using parallel compilation with ${MAKE_JOBS} jobs"
fi

# -----------------------------
# Build strfry
# -----------------------------
mkdir -p "$RUNTIME_CONFIG_DIR"
cd "$STRFRY_DIR"

# Determine current submodule commit (if available) and decide whether to build
BUILD_STATE_FILE="$RUNTIME_CONFIG_DIR/strfry_build.sha"
if [ -f ".commit" ]; then
    CURRENT_SUBMODULE_SHA="$(cat .commit | tr -d '\r\n' || echo unknown)"
else
    CURRENT_SUBMODULE_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
fi

if [ -x "strfry" ] && [ -f "$BUILD_STATE_FILE" ] && grep -qx "$CURRENT_SUBMODULE_SHA" "$BUILD_STATE_FILE"; then
    echo "✅ strfry already built for commit $CURRENT_SUBMODULE_SHA; skipping compilation"
else
    if [ -x "strfry" ] && [ "$CURRENT_SUBMODULE_SHA" = "unknown" ]; then
        echo "✅ strfry binary present and current commit unknown; skipping compilation"
    else
        echo "🔨 Starting strfry compilation (target commit: $CURRENT_SUBMODULE_SHA)..."
        # Clean any previous failed builds only if we are about to compile
        if [ -d "build" ]; then
            echo "🧹 Cleaning previous build artifacts..."
            rm -rf build/
        fi

        git submodule update --init
        make setup-golpe

        echo "⚡ Compiling strfry with ${MAKE_JOBS} parallel jobs..."
        make -j${MAKE_JOBS}
    fi
    # Record the commit we compiled for (if known)
    if [ "$CURRENT_SUBMODULE_SHA" != "unknown" ]; then
        echo "$CURRENT_SUBMODULE_SHA" > "$BUILD_STATE_FILE"
    fi
fi

# -----------------------------
# Ensure default config doesn't interfere
# -----------------------------
if [ -f "strfry.conf" ]; then
    echo "📋 Backing up default strfry config to prevent interference..."
    mv strfry.conf strfry.conf.default
fi

# -----------------------------
# Deploy runtime config
# -----------------------------
mkdir -p "$RUNTIME_CONFIG_DIR"
cp "$CONFIG_DIR/strfry.conf" "$RUNTIME_CONFIG_DIR/strfry.conf"

# Ensure plugin is executable
chmod +x "$REPO_DIR/plugins/nip05_gate.py"

# -----------------------------
# Ensure data directory exists
# -----------------------------
mkdir -p "$DATA_DIR"

# -----------------------------
# Deploy systemd service
# -----------------------------
sudo cp "$CONFIG_DIR/strfry.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable strfry
sudo systemctl restart strfry

# -----------------------------
# Post-deploy smoke test
# -----------------------------
STRFRY_BIN="$STRFRY_DIR/strfry"
if [ -x "$STRFRY_BIN" ]; then
    "$STRFRY_BIN" --config "$RUNTIME_CONFIG_DIR/strfry.conf" --version || \
    "$STRFRY_BIN" --config "$RUNTIME_CONFIG_DIR/strfry.conf" --help
    echo "✅ strfry build and deploy successful"
else
    echo "❌ strfry binary not found or not executable"
    echo "Expected location: $STRFRY_BIN"
    ls -la "$STRFRY_DIR/"
    exit 1
fi