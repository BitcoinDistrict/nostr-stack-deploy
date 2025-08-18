#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh" "${DEPLOY_ENV:-}"

SITE_PATH="/etc/nginx/sites-available/${DOMAIN}"
ENABLED_PATH="/etc/nginx/sites-enabled/${DOMAIN}"

sudo mkdir -p /var/www/certbot

# Render initial HTTP config
envsubst < "${CONFIGS_DIR}/nginx/relay-http.conf.template" | sudo tee "${SITE_PATH}" >/dev/null
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

# If certificate exists, render HTTPS config
if [ "$CERT_STATUS" = "ok" ] || [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
  envsubst < "${CONFIGS_DIR}/nginx/relay-https.conf.template" | sudo tee "${SITE_PATH}" >/dev/null
  sudo nginx -t
  sudo systemctl reload nginx
fi


