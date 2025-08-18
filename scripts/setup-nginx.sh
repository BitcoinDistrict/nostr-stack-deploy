#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh" "${DEPLOY_ENV:-}"

SITE_PATH="/etc/nginx/sites-available/${DOMAIN}"
ENABLED_PATH="/etc/nginx/sites-enabled/${DOMAIN}"

# Clean up any accidentally created files from previous buggy runs (filenames containing 'DOMAIN=')
sudo find /etc/nginx/sites-available -maxdepth 1 -type f -name "*DOMAIN=*" -print -exec sudo rm -f {} + || true
sudo find /etc/nginx/sites-enabled -maxdepth 1 -type l -name "*DOMAIN=*" -print -exec sudo rm -f {} + || true

# Remove stale site files/symlinks that may shadow the generated vhost
# Historically we used ".conf" suffix; ensure only "${DOMAIN}" remains active
sudo rm -f \
  "/etc/nginx/sites-available/${DOMAIN}.conf" \
  "/etc/nginx/sites-enabled/${DOMAIN}.conf" || true
sudo rm -f "/etc/nginx/sites-enabled/${DOMAIN}" || true

# Fix accidental directory/symlink inside sites-enabled (breaks nginx include)
if [ -L "/etc/nginx/sites-enabled/sites-available" ]; then
  sudo rm -f "/etc/nginx/sites-enabled/sites-available" || true
fi
if [ -d "/etc/nginx/sites-enabled/sites-available" ]; then
  sudo rm -rf "/etc/nginx/sites-enabled/sites-available" || true
fi

sudo mkdir -p /var/www/certbot

# Render initial HTTP config (only substitute ${DOMAIN}; preserve $http_* vars)
envsubst '${DOMAIN}' < "${CONFIGS_DIR}/nginx/relay-http.conf.template" | sudo tee "${SITE_PATH}" >/dev/null
sudo ln -sf "${SITE_PATH}" "${ENABLED_PATH}"
sudo nginx -t
sudo systemctl reload nginx

# Obtain certificate
CERT_STATUS="failed"
if [ "${CLOUDFLARE_ENABLED}" = "true" ] && [ -n "${CLOUDFLARE_API_TOKEN}" ]; then
  CLOUDFLARE_INI="/etc/letsencrypt/cloudflare.ini"
  echo "dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}" | sudo tee "$CLOUDFLARE_INI" >/dev/null
  sudo chmod 600 "$CLOUDFLARE_INI"
  if sudo certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CLOUDFLARE_INI" \
      --dns-cloudflare-propagation-seconds 60 -d "${DOMAIN}" --non-interactive --agree-tos -m "${CERTBOT_EMAIL}"; then
    CERT_STATUS="ok"
  fi
else
  if sudo certbot certonly --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "${CERTBOT_EMAIL}"; then
    CERT_STATUS="ok"
  fi
fi

# Normalize live cert path (handles certbot creating -0001, -0002 lineages)
CERT_DIR_REAL=""
for pem in /etc/letsencrypt/live/${DOMAIN}*/fullchain.pem; do
  if [ -f "$pem" ]; then
    CERT_DIR_REAL="$(dirname "$pem")"
    break
  fi
done
if [ "$CERT_STATUS" = "ok" ] || [ -n "${CERT_DIR_REAL}" ]; then
  if [ -n "${CERT_DIR_REAL}" ] && [ "${CERT_DIR_REAL}" != "/etc/letsencrypt/live/${DOMAIN}" ]; then
    sudo ln -sfn "${CERT_DIR_REAL}" "/etc/letsencrypt/live/${DOMAIN}"
  fi
  envsubst '${DOMAIN}' < "${CONFIGS_DIR}/nginx/relay-https.conf.template" | sudo tee "${SITE_PATH}" >/dev/null
  sudo nginx -t
  sudo systemctl reload nginx
fi


