#!/usr/bin/env bash
set -euo pipefail

# This script removes services, configs, nginx vhosts, and optional data for a clean redeploy.
# It is idempotent and safe to re-run. Requires sudo for system-level changes.

to_bool() {
    case "${1:-}" in
        [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Yy]|[Oo][Nn]) return 0 ;;
        *) return 1 ;;
    esac
}

# Parameters (env-overridable)
DOMAIN="${DOMAIN:-relay.bitcoindistrict.org}"
BLOSSOM_DOMAIN="${BLOSSOM_DOMAIN:-media.${DOMAIN}}"
PRESERVE_DATA="${PRESERVE_DATA:-true}"      # set to false to remove data directories
PRESERVE_CERTS="${PRESERVE_CERTS:-true}"    # set to false to remove Let's Encrypt certs

echo "🧹 Uninstalling Nostr stack (strfry + blossom + auth proxy)..."

echo "🔧 Stopping services if running..."
sudo systemctl stop strfry 2>/dev/null || true
sudo systemctl stop blossom 2>/dev/null || true
sudo systemctl stop nostr-auth-proxy 2>/dev/null || true

echo "🗄️ Disabling services..."
sudo systemctl disable strfry 2>/dev/null || true
sudo systemctl disable blossom 2>/dev/null || true
sudo systemctl disable nostr-auth-proxy 2>/dev/null || true
sudo systemctl daemon-reload || true

echo "🧾 Removing systemd unit files..."
sudo rm -f /etc/systemd/system/strfry.service || true
sudo rm -f /etc/systemd/system/blossom.service || true
sudo rm -f /etc/systemd/system/nostr-auth-proxy.service || true
sudo systemctl daemon-reload || true

echo "🌐 Removing nginx vhosts..."
sudo rm -f "/etc/nginx/sites-enabled/${DOMAIN}" "/etc/nginx/sites-available/${DOMAIN}" || true
if [ -n "${BLOSSOM_DOMAIN}" ]; then
  sudo rm -f "/etc/nginx/sites-enabled/${BLOSSOM_DOMAIN}" "/etc/nginx/sites-available/${BLOSSOM_DOMAIN}" || true
fi
sudo nginx -t 2>/dev/null && sudo systemctl reload nginx || true

echo "🧩 Removing auth proxy defaults/env..."
sudo rm -f /etc/default/nostr-auth-proxy || true

echo "🌸 Removing blossom defaults and config..."
sudo rm -f /etc/default/blossom || true
sudo rm -f /etc/blossom/config.yml || true

if to_bool "$PRESERVE_DATA"; then
  echo "💾 Preserving data directories (set PRESERVE_DATA=false to delete)."
else
  echo "🗑️ Deleting data directories..."
  sudo rm -rf /var/lib/blossom || true
  # strfry data is usually in ~/nostr-stack-deploy/strfry-db (user-owned)
  if [ -d "$HOME/nostr-stack-deploy/strfry-db" ]; then
    rm -rf "$HOME/nostr-stack-deploy/strfry-db"
  fi
fi

echo "🧹 Cleaning runtime relay config..."
rm -f "$HOME/.strfry/strfry.conf" 2>/dev/null || true

if to_bool "$PRESERVE_CERTS"; then
  echo "🔒 Preserving Let's Encrypt certificates (set PRESERVE_CERTS=false to delete)."
else
  echo "🧨 Deleting Let's Encrypt certificates..."
  sudo rm -rf "/etc/letsencrypt/live/${DOMAIN}" \
              "/etc/letsencrypt/archive/${DOMAIN}" \
              "/etc/letsencrypt/renewal/${DOMAIN}.conf" || true
  if [ -n "${BLOSSOM_DOMAIN}" ]; then
    sudo rm -rf "/etc/letsencrypt/live/${BLOSSOM_DOMAIN}" \
                "/etc/letsencrypt/archive/${BLOSSOM_DOMAIN}" \
                "/etc/letsencrypt/renewal/${BLOSSOM_DOMAIN}.conf" || true
  fi
fi

echo "🐳 Cleaning Docker containers/images (if present)..."
if command -v docker >/dev/null 2>&1; then
  sudo docker rm -f blossom-server 2>/dev/null || true
  sudo docker rm -f nostr-auth-proxy 2>/dev/null || true
  sudo docker rmi -f nostr-auth-proxy:local 2>/dev/null || true
fi

echo "✅ Uninstall complete. You can redeploy cleanly with scripts/deploy.sh"


