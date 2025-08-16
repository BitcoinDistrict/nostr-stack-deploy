#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Paths
# -----------------------------
REPO_DIR="$HOME/nostr-stack-deploy"
STRFRY_DIR="$REPO_DIR/strfry"
CONFIG_DIR="$REPO_DIR/configs"
RUNTIME_CONFIG_DIR="$HOME/.strfry"
DATA_DIR="$HOME/nostr-stack-deploy/strfry-db"

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
sudo apt-get install -y nginx certbot python3-certbot-nginx

# Copy nginx config
sudo cp "$CONFIG_DIR/nginx/relay.bitcoindistrict.org.conf" /etc/nginx/sites-available/relay.bitcoindistrict.org

# Enable the site
sudo ln -sf /etc/nginx/sites-available/relay.bitcoindistrict.org /etc/nginx/sites-enabled/

# Test nginx config
sudo nginx -t

# Reload nginx
sudo systemctl reload nginx

echo "✅ Nginx configured for relay.bitcoindistrict.org"

# -----------------------------
# Configure SSL certificate (optional - requires domain to be accessible)
# -----------------------------
echo "🔒 Attempting to configure SSL certificate..."
if sudo certbot --nginx -d relay.bitcoindistrict.org --non-interactive --agree-tos --email hey@bitcoindistrict.org; then
    echo "✅ SSL certificate configured successfully"
else
    echo "⚠️  SSL certificate setup failed (domain may not be accessible yet)"
    echo "   You can run this manually later: sudo certbot --nginx -d relay.bitcoindistrict.org"
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
sudo ufw allow 7777/tcp
sudo ufw allow 'Nginx Full'  # Allow HTTP (80) and HTTPS (443)
echo "✅ Firewall configured: SSH, port 7777, and Nginx (HTTP/HTTPS) allowed"

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
cd "$STRFRY_DIR"

# Check if binary already exists and is executable
if [ -x "strfry" ]; then
    echo "✅ strfry binary already exists, skipping compilation"
else
    echo "🔨 Starting strfry compilation..."
    
    # Clean any previous failed builds only if binary doesn't exist
    if [ -d "build" ]; then
        echo "🧹 Cleaning previous build artifacts..."
        rm -rf build/
    fi

    git submodule update --init
    make setup-golpe

    echo "⚡ Compiling strfry with ${MAKE_JOBS} parallel jobs..."
    make -j${MAKE_JOBS}
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