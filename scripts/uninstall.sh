#!/usr/bin/env bash
set -euo pipefail

# Uninstall the nostr stack (relay/strfry, blossom, auth proxy, dashboard) from this server.
# Defaults: preserve data and preserve certificates.
#
# Options (env or flags):
#   --domain DOMAIN                     Relay domain (optional; auto-detect if omitted)
#   --dashboard-domain DOMAIN           Dashboard domain (optional; auto-detect if omitted)
#   --blossom-domain DOMAIN             Blossom domain (optional; auto-detect if omitted)
#   --purge-data                        Remove data directories (/var/lib/blossom, ~/.strfry, strfry-db, /var/www/relay-dashboard)
#   --purge-certs                       Delete Let's Encrypt certs for detected/passed domains, and ACME webroot
#   --purge-cloudflare-ini              Delete /etc/letsencrypt/cloudflare.ini (if present)
#   --purge-docker-images               Remove docker images (nostr-auth-proxy:local and blossom image)
#   -y | --yes                          Non-interactive (assume yes to prompts)
#
# Example:
#   scripts/uninstall.sh --domain relay.example.com --blossom-domain media.example.com --purge-data

DOMAIN="${DOMAIN:-}"
DASHBOARD_DOMAIN="${DASHBOARD_DOMAIN:-}"
BLOSSOM_DOMAIN="${BLOSSOM_DOMAIN:-}"

PURGE_DATA=false
PURGE_CERTS=false
PURGE_CLOUDFLARE_INI=false
PURGE_DOCKER_IMAGES=false
ASSUME_YES=false

# Paths (match deploy.sh conventions)
REPO_DIR="$HOME/nostr-stack-deploy"
RUNTIME_CONFIG_DIR="$HOME/.strfry"
DATA_DIR="$HOME/nostr-stack-deploy/strfry-db"

# Colors
bold() { printf "\033[1m%s\033[0m\n" "$*"; }

confirm() {
    if [ "$ASSUME_YES" = true ]; then
        return 0
    fi
    read -r -p "$1 [y/N]: " ans || true
    case "${ans:-}" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --domain DOMAIN                    Relay domain (nginx site name)
  --dashboard-domain DOMAIN          Dashboard domain (nginx site name)
  --blossom-domain DOMAIN            Blossom domain (nginx site name)
  --purge-data                       Remove data and runtime dirs (PRESERVE by default)
  --purge-certs                      Delete Let's Encrypt certs for the domains (PRESERVE by default)
  --purge-cloudflare-ini             Delete /etc/letsencrypt/cloudflare.ini
  --purge-docker-images              Remove docker images used by this stack
  -y, --yes                          Non-interactive (assume yes)
  -h, --help                         Show this help
EOF
}

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --dashboard-domain) DASHBOARD_DOMAIN="$2"; shift 2 ;;
        --blossom-domain) BLOSSOM_DOMAIN="$2"; shift 2 ;;
        --purge-data) PURGE_DATA=true; shift ;;
        --purge-certs) PURGE_CERTS=true; shift ;;
        --purge-cloudflare-ini) PURGE_CLOUDFLARE_INI=true; shift ;;
        --purge-docker-images) PURGE_DOCKER_IMAGES=true; shift ;;
        -y|--yes) ASSUME_YES=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

ensure_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing command: $1"; return 1;
    }
}

nginx_site_disable_and_remove() {
    local site="$1"
    [ -z "$site" ] && return 0
    local avail="/etc/nginx/sites-available/$site"
    local enabled="/etc/nginx/sites-enabled/$site"
    if [ -L "$enabled" ] || [ -f "$enabled" ]; then
        sudo rm -f "$enabled" || true
        echo "- removed sites-enabled/$site"
    fi
    if [ -f "$avail" ]; then
        sudo rm -f "$avail" || true
        echo "- removed sites-available/$site"
    fi
}

find_domain_by_pattern() {
    # Args: grep_pattern
    local pattern="$1"
    local d
    for d in $(ls /etc/nginx/sites-available 2>/dev/null || true); do
        if sudo grep -q "$pattern" "/etc/nginx/sites-available/$d" 2>/dev/null; then
            echo "$d"
            return 0
        fi
    done
    # Fallback: try in sites-enabled
    for d in $(ls /etc/nginx/sites-enabled 2>/dev/null || true); do
        if sudo grep -q "$pattern" "/etc/nginx/sites-enabled/$d" 2>/dev/null; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

bold "Detecting domains (if not provided) ..."
if [ -z "${DOMAIN:-}" ]; then
    DOMAIN=$(find_domain_by_pattern "upstream strfry_ws" || true)
fi
if [ -z "${BLOSSOM_DOMAIN:-}" ]; then
    BLOSSOM_DOMAIN=$(find_domain_by_pattern "upstream blossom_upstream" || true)
fi
if [ -z "${DASHBOARD_DOMAIN:-}" ]; then
    DASHBOARD_DOMAIN=$(find_domain_by_pattern "root /var/www/relay-dashboard" || true)
fi

echo "Resolved domains:"
echo "  Relay DOMAIN=\"${DOMAIN:-<unknown>}\""
echo "  Blossom BLOSSOM_DOMAIN=\"${BLOSSOM_DOMAIN:-<unknown>}\""
echo "  Dashboard DASHBOARD_DOMAIN=\"${DASHBOARD_DOMAIN:-<unknown>}\""

bold "Stopping and disabling services ..."
SERVICES=(
    strfry
    blossom
    nostr-auth-proxy
    relay-dashboard
    relay-dashboard-stats.timer
    relay-dashboard-stats.service
)

for svc in "${SERVICES[@]}"; do
    if systemctl list-unit-files | grep -q "^${svc}\."; then
        if systemctl is-active --quiet "$svc"; then
            sudo systemctl stop "$svc" || true
        fi
        if systemctl is-enabled --quiet "$svc"; then
            sudo systemctl disable "$svc" || true
        fi
    fi
done

bold "Removing systemd unit files ..."
SYSTEMD_UNITS=(
    /etc/systemd/system/strfry.service
    /etc/systemd/system/blossom.service
    /etc/systemd/system/nostr-auth-proxy.service
    /etc/systemd/system/relay-dashboard.service
    /etc/systemd/system/relay-dashboard-stats.service
    /etc/systemd/system/relay-dashboard-stats.timer
)
for unit in "${SYSTEMD_UNITS[@]}"; do
    if [ -f "$unit" ]; then
        sudo rm -f "$unit" || true
        echo "- removed $unit"
    fi
done
sudo systemctl daemon-reload || true

bold "Removing /etc/default env files ..."
for envf in /etc/default/blossom /etc/default/nostr-auth-proxy; do
    if [ -f "$envf" ]; then
        sudo rm -f "$envf" || true
        echo "- removed $envf"
    fi
done

bold "Removing nginx sites ..."
if [ -n "${DOMAIN:-}" ]; then
    nginx_site_disable_and_remove "$DOMAIN"
fi
if [ -n "${BLOSSOM_DOMAIN:-}" ]; then
    nginx_site_disable_and_remove "$BLOSSOM_DOMAIN"
fi
if [ -n "${DASHBOARD_DOMAIN:-}" ]; then
    nginx_site_disable_and_remove "$DASHBOARD_DOMAIN"
fi

if ensure_cmd nginx && ensure_cmd sudo; then
    if sudo nginx -t; then
        sudo systemctl reload nginx || true
    else
        echo "Warning: nginx config test failed. Skipping reload."
    fi
fi

bold "Stopping leftover docker containers (if any) ..."
if command -v docker >/dev/null 2>&1; then
    docker rm -f blossom-server 2>/dev/null || true
    docker rm -f nostr-auth-proxy 2>/dev/null || true
else
    echo "docker not installed; skipping container cleanup"
fi

bold "Removing Blossom configuration ..."
if [ -d /etc/blossom ]; then
    sudo rm -rf /etc/blossom || true
    echo "- removed /etc/blossom"
fi

bold "Optional data purge ..."
if [ "$PURGE_DATA" = true ]; then
    if confirm "Purge data directories (this cannot be undone)?"; then
        # strfry runtime config
        if [ -d "$RUNTIME_CONFIG_DIR" ]; then
            rm -rf "$RUNTIME_CONFIG_DIR" || true
            echo "- removed $RUNTIME_CONFIG_DIR"
        fi
        # strfry data
        if [ -d "$DATA_DIR" ]; then
            rm -rf "$DATA_DIR" || true
            echo "- removed $DATA_DIR"
        fi
        # blossom data
        if [ -d /var/lib/blossom ]; then
            sudo rm -rf /var/lib/blossom || true
            echo "- removed /var/lib/blossom"
        fi
        # dashboard root
        if [ -d /var/www/relay-dashboard ]; then
            sudo rm -rf /var/www/relay-dashboard || true
            echo "- removed /var/www/relay-dashboard"
        fi
    else
        echo "Skipped data purge."
    fi
else
    echo "Data preserved (use --purge-data to remove)."
fi

bold "Optional cert purge ..."
if [ "$PURGE_CERTS" = true ]; then
    if confirm "Delete Let's Encrypt certificates for the domains?"; then
        if command -v certbot >/dev/null 2>&1; then
            for d in ${DOMAIN:-} ${BLOSSOM_DOMAIN:-} ${DASHBOARD_DOMAIN:-}; do
                if [ -n "$d" ]; then
                    sudo certbot delete --cert-name "$d" -n || true
                fi
            done
        fi
        # ACME webroot used in deploy
        if [ -d /var/www/certbot ]; then
            sudo rm -rf /var/www/certbot || true
            echo "- removed /var/www/certbot"
        fi
    else
        echo "Skipped cert purge."
    fi
else
    echo "Certificates preserved (use --purge-certs to remove)."
fi

if [ "$PURGE_CLOUDFLARE_INI" = true ]; then
    if [ -f /etc/letsencrypt/cloudflare.ini ]; then
        sudo rm -f /etc/letsencrypt/cloudflare.ini || true
        echo "- removed /etc/letsencrypt/cloudflare.ini"
    fi
fi

bold "Optional docker image cleanup ..."
if [ "$PURGE_DOCKER_IMAGES" = true ] && command -v docker >/dev/null 2>&1; then
    # Read blossom image from /etc/default/blossom if present
    BLOSSOM_IMAGE_ENV=""
    if [ -f /etc/default/blossom ]; then
        BLOSSOM_IMAGE_ENV=$(grep -E '^BLOSSOM_CONTAINER_IMAGE=' /etc/default/blossom | sed 's/^BLOSSOM_CONTAINER_IMAGE=//') || true
    fi
    # Fallback to commonly used tag
    BLOSSOM_IMAGE_ENV=${BLOSSOM_IMAGE_ENV:-ghcr.io/hzrd149/blossom-server:master}
    docker rmi -f nostr-auth-proxy:local 2>/dev/null || true
    docker rmi -f "$BLOSSOM_IMAGE_ENV" 2>/dev/null || true
fi

bold "Done. The nostr stack has been uninstalled from this server with the selected options."


