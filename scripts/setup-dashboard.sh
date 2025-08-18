#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh" "${DEPLOY_ENV:-}"

if ! to_bool "${DASHBOARD_ENABLED}"; then
  echo "Dashboard disabled"
  exit 0
fi

SITE_PATH="/etc/nginx/sites-available/${DASHBOARD_DOMAIN}"
ENABLED_PATH="/etc/nginx/sites-enabled/${DASHBOARD_DOMAIN}"

sudo mkdir -p /var/www/relay-dashboard
sudo cp -r "${REPO_DIR}/web/relay-dashboard/"* /var/www/relay-dashboard/
sudo chown -R deploy:deploy /var/www/relay-dashboard || true

cat << 'EOF' | sudo tee "${SITE_PATH}" >/dev/null
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
sudo sed -i "s/DASHBOARD_DOMAIN_PLACEHOLDER/${DASHBOARD_DOMAIN}/g" "${SITE_PATH}"
sudo ln -sf "${SITE_PATH}" "${ENABLED_PATH}"
sudo nginx -t && sudo systemctl reload nginx

# Cert
if [ "${CLOUDFLARE_ENABLED}" = "true" ] && [ -n "${CLOUDFLARE_API_TOKEN}" ]; then
  CLOUDFLARE_INI="/etc/letsencrypt/cloudflare.ini"
  echo "dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}" | sudo tee "$CLOUDFLARE_INI" >/dev/null
  sudo chmod 600 "$CLOUDFLARE_INI"
  sudo certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CLOUDFLARE_INI" \
      --dns-cloudflare-propagation-seconds 60 -d "${DASHBOARD_DOMAIN}" --non-interactive --agree-tos -m "${CERTBOT_EMAIL}" || true
else
  sudo certbot certonly --nginx -d "${DASHBOARD_DOMAIN}" --non-interactive --agree-tos -m "${CERTBOT_EMAIL}" || true
fi

if [ -f "/etc/letsencrypt/live/${DASHBOARD_DOMAIN}/fullchain.pem" ]; then
cat << 'EOF' | sudo tee "${SITE_PATH}" >/dev/null
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
  sudo sed -i "s/DASHBOARD_DOMAIN_PLACEHOLDER/${DASHBOARD_DOMAIN}/g" "${SITE_PATH}"
  sudo nginx -t && sudo systemctl reload nginx
fi

sudo cp "${REPO_DIR}/configs/dashboard/relay-dashboard.service" /etc/systemd/system/
sudo cp "${REPO_DIR}/configs/dashboard/relay-dashboard-stats.service" /etc/systemd/system/
sudo cp "${REPO_DIR}/configs/dashboard/relay-dashboard-stats.timer" /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable relay-dashboard.service
sudo systemctl start relay-dashboard.service
sudo systemctl enable relay-dashboard-stats.timer
sudo systemctl start relay-dashboard-stats.timer
sudo systemctl start relay-dashboard-stats.service || true


