#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh" "${DEPLOY_ENV:-}"

if ! to_bool "${BLOSSOM_ENABLED}"; then
  echo "Blossom disabled"
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sudo sh
  sudo systemctl enable --now docker || true
  sudo usermod -aG docker "$USER" || true
fi

sudo mkdir -p /var/lib/blossom /etc/blossom /etc/default /var/www/certbot
sudo chown -R deploy:deploy /var/lib/blossom || true
sudo mkdir -p /var/www/blossom-ui
sudo cp -r "${REPO_DIR}/web/blossom-ui/"* /var/www/blossom-ui/ || true

# Render blossom config
# Prefer template if present, else fallback to current config with env expansion
if [ -f "${CONFIGS_DIR}/blossom/config.yml.template" ]; then
  envsubst '${BLOSSOM_PORT} ${BLOSSOM_DOMAIN} ${BLOSSOM_MAX_UPLOAD_MB}' < "${CONFIGS_DIR}/blossom/config.yml.template" | sudo tee /etc/blossom/config.yml >/dev/null
else
  envsubst '${BLOSSOM_PORT} ${BLOSSOM_DOMAIN} ${BLOSSOM_MAX_UPLOAD_MB}' < "${CONFIGS_DIR}/blossom/config.yml" | sudo tee /etc/blossom/config.yml >/dev/null
fi

# /etc/default env files
cat <<EOF | sudo tee /etc/default/blossom >/dev/null
BLOSSOM_CONTAINER_IMAGE=${BLOSSOM_CONTAINER_IMAGE}
BLOSSOM_PORT=${BLOSSOM_PORT}
EOF

cat <<EOF | sudo tee /etc/default/nostr-auth-proxy >/dev/null
NOSTR_AUTH_PORT=${NOSTR_AUTH_PORT}
NOSTR_AUTH_GATE_MODE=${NOSTR_AUTH_GATE_MODE}
NOSTR_AUTH_CACHE_TTL_SECONDS=${NOSTR_AUTH_CACHE_TTL_SECONDS}
NOSTR_AUTH_LOG_LEVEL=${NOSTR_AUTH_LOG_LEVEL}
NOSTR_AUTH_ALLOWLIST_FILE=${NOSTR_AUTH_ALLOWLIST_FILE}
EOF

# Systemd units
cat << EOF | sudo tee /etc/systemd/system/nostr-auth-proxy.service >/dev/null
[Unit]
Description=Nostr Auth Proxy (NIP-98 + NIP-05)
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
EnvironmentFile=-/etc/default/nostr-auth-proxy
ExecStartPre=/usr/bin/docker build -t nostr-auth-proxy:local ${REPO_DIR}/scripts/nostr-auth-proxy
ExecStart=/bin/bash -lc '/usr/bin/docker run --rm \
  --name nostr-auth-proxy \
  -p 127.0.0.1:${NOSTR_AUTH_PORT:-3310}:3000 \
  -e PORT=3000 \
  -e GATE_MODE=${NOSTR_AUTH_GATE_MODE:-nip05} \
  -e CACHE_TTL=${NOSTR_AUTH_CACHE_TTL_SECONDS:-300} \
  -e LOG_LEVEL=${NOSTR_AUTH_LOG_LEVEL:-info} \
  -e ALLOWLIST_FILE=${NOSTR_AUTH_ALLOWLIST_FILE:-} \
  VOLUME_MOUNT_PLACEHOLDER \
  nostr-auth-proxy:local'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

if [ "${NOSTR_AUTH_GATE_MODE}" = "allowlist" ] && [ -n "${NOSTR_AUTH_ALLOWLIST_FILE:-}" ]; then
  sudo sed -i 's|VOLUME_MOUNT_PLACEHOLDER|  -v '"${NOSTR_AUTH_ALLOWLIST_FILE}:${NOSTR_AUTH_ALLOWLIST_FILE}:ro"'|' /etc/systemd/system/nostr-auth-proxy.service
else
  sudo sed -i 's|VOLUME_MOUNT_PLACEHOLDER||' /etc/systemd/system/nostr-auth-proxy.service
fi

sudo cp "${CONFIGS_DIR}/blossom/blossom.service" /etc/systemd/system/blossom.service
sudo systemctl daemon-reload

if to_bool "${NOSTR_AUTH_ENABLED}"; then
  sudo systemctl enable nostr-auth-proxy.service
  sudo systemctl restart nostr-auth-proxy.service
fi

sudo systemctl enable blossom.service
sudo systemctl restart blossom.service

# Nginx HTTP vhost for ACME
BLOSSOM_SITE_PATH="/etc/nginx/sites-available/${BLOSSOM_DOMAIN}"
# Ensure no stale .conf files shadow this vhost before writing
sudo rm -f \
  "/etc/nginx/sites-available/${BLOSSOM_DOMAIN}.conf" \
  "/etc/nginx/sites-enabled/${BLOSSOM_DOMAIN}.conf" || true
sudo rm -f "/etc/nginx/sites-enabled/${BLOSSOM_DOMAIN}" || true
# Fix accidental directory/symlink inside sites-enabled (breaks nginx include)
if [ -L "/etc/nginx/sites-enabled/sites-available" ]; then
  sudo rm -f "/etc/nginx/sites-enabled/sites-available" || true
fi
if [ -d "/etc/nginx/sites-enabled/sites-available" ]; then
  sudo rm -rf "/etc/nginx/sites-enabled/sites-available" || true
fi
envsubst '${BLOSSOM_DOMAIN} ${BLOSSOM_PORT}' < "${CONFIGS_DIR}/nginx/blossom-http.conf.template" | sudo tee "${BLOSSOM_SITE_PATH}" >/dev/null
sudo ln -sf "${BLOSSOM_SITE_PATH}" "/etc/nginx/sites-enabled/${BLOSSOM_DOMAIN}"
sudo nginx -t && sudo systemctl reload nginx

# Cert for Blossom
echo "[blossom] Using CONFIGS_DIR=${CONFIGS_DIR}, BLOSSOM_DOMAIN=${BLOSSOM_DOMAIN}"
if [ "${CLOUDFLARE_ENABLED}" = "true" ] && [ -n "${CLOUDFLARE_API_TOKEN}" ]; then
  CLOUDFLARE_INI="/etc/letsencrypt/cloudflare.ini"
  echo "dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}" | sudo tee "$CLOUDFLARE_INI" >/dev/null
  sudo chmod 600 "$CLOUDFLARE_INI"
  sudo certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CLOUDFLARE_INI" \
    --dns-cloudflare-propagation-seconds 60 -d "${BLOSSOM_DOMAIN}" --non-interactive --agree-tos -m "${CERTBOT_EMAIL}" || true
else
  sudo certbot certonly --nginx -d "${BLOSSOM_DOMAIN}" --non-interactive --agree-tos -m "${CERTBOT_EMAIL}" || true
fi

# Normalize live cert path (handles certbot creating -0001, -0002 lineages)
CERT_DIR_REAL=""
for pem in /etc/letsencrypt/live/${BLOSSOM_DOMAIN}*/fullchain.pem; do
  if [ -f "$pem" ]; then
    CERT_DIR_REAL="$(dirname "$pem")"
    break
  fi
done
if [ -n "${CERT_DIR_REAL}" ] && [ "${CERT_DIR_REAL}" != "/etc/letsencrypt/live/${BLOSSOM_DOMAIN}" ]; then
  echo "[blossom] Linking cert lineage: ${CERT_DIR_REAL} -> /etc/letsencrypt/live/${BLOSSOM_DOMAIN}"
  sudo ln -sfn "${CERT_DIR_REAL}" "/etc/letsencrypt/live/${BLOSSOM_DOMAIN}"
fi

# Ensure no stale .conf files shadow this vhost
sudo rm -f \
  "/etc/nginx/sites-available/${BLOSSOM_DOMAIN}.conf" \
  "/etc/nginx/sites-enabled/${BLOSSOM_DOMAIN}.conf" || true
sudo rm -f "/etc/nginx/sites-enabled/${BLOSSOM_DOMAIN}" || true

# Try to render HTTPS first; if nginx -t fails, fall back to HTTP
echo "[blossom] Attempting HTTPS vhost render"
envsubst '${BLOSSOM_DOMAIN} ${BLOSSOM_PORT} ${NOSTR_AUTH_PORT} ${BLOSSOM_MAX_UPLOAD_MB}' < "${CONFIGS_DIR}/nginx/blossom.conf.template" | sudo tee "${BLOSSOM_SITE_PATH}" >/dev/null
if [ "${BLOSSOM_GATE_MODE}" = "open" ] || ! to_bool "${NOSTR_AUTH_ENABLED}"; then
  sudo sed -i "/auth_request \\/__auth;/d" "${BLOSSOM_SITE_PATH}"
fi
sudo ln -sf "${BLOSSOM_SITE_PATH}" "/etc/nginx/sites-enabled/${BLOSSOM_DOMAIN}"
if sudo nginx -t >/dev/null 2>&1; then
  sudo systemctl reload nginx
  echo "[blossom] HTTPS vhost applied"
else
  echo "[blossom] HTTPS vhost test failed; falling back to HTTP"
  envsubst '${BLOSSOM_DOMAIN} ${BLOSSOM_PORT}' < "${CONFIGS_DIR}/nginx/blossom-http.conf.template" | sudo tee "${BLOSSOM_SITE_PATH}" >/dev/null
  sudo ln -sf "${BLOSSOM_SITE_PATH}" "/etc/nginx/sites-enabled/${BLOSSOM_DOMAIN}"
  sudo nginx -t && sudo systemctl reload nginx
fi


