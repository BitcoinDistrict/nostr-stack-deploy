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
# Configure firewall
# -----------------------------
sudo ufw --force enable
sudo ufw allow ssh
sudo ufw allow 7777/tcp
echo "✅ Firewall configured: SSH and port 7777 allowed"

# -----------------------------
# Build strfry
# -----------------------------
cd "$STRFRY_DIR"
git submodule update --init
make setup-golpe
make -j$(nproc)

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
STRFRY_BIN="$STRFRY_DIR/build/strfry"
if [ -x "$STRFRY_BIN" ]; then
    "$STRFRY_BIN" --config "$RUNTIME_CONFIG_DIR/strfry.conf" --version || \
    "$STRFRY_BIN" --config "$RUNTIME_CONFIG_DIR/strfry.conf" --help
    echo "✅ strfry build and deploy successful"
else
    echo "❌ strfry binary not found or not executable"
    exit 1
fi