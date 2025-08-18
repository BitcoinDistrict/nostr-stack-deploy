#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh" "${DEPLOY_ENV:-}"

sudo apt-get update -y
sudo apt-get install -y \
  build-essential libsqlite3-dev libssl-dev pkg-config \
  liblmdb-dev libflatbuffers-dev libsecp256k1-dev libzstd-dev zlib1g-dev \
  nginx certbot python3-certbot-nginx python3-certbot-dns-cloudflare jq ufw gettext-base

# Firewall
sudo ufw --force enable || true
sudo ufw allow 'Nginx Full' || true
sudo ufw allow ssh || true

# Swap (2GB if missing)
if [ ! -f /swapfile ]; then
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  if ! grep -q "/swapfile" /etc/fstab; then
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  fi
fi


