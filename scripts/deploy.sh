#!/usr/bin/env bash
set -euo pipefail

# Orchestrator for modular deployment. To use legacy monolith, run scripts/deploy_legacy.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration and helpers
source "${SCRIPT_DIR}/config.sh" "${DEPLOY_ENV:-}"

echo "Deploying Nostr stack"
echo "  DEPLOY_ENV=${DEPLOY_ENV}"
echo "  DOMAIN=${DOMAIN}"
echo "  DASHBOARD_ENABLED=${DASHBOARD_ENABLED} (${DASHBOARD_DOMAIN})"
echo "  BLOSSOM_ENABLED=${BLOSSOM_ENABLED} (${BLOSSOM_DOMAIN})"

# 1) Base OS setup (packages, swap, firewall)
bash "${SCRIPT_DIR}/setup-system.sh"

# 2) Nginx + certificates for relay domain
bash "${SCRIPT_DIR}/setup-nginx.sh"

# 3) strfry build and setup
bash "${SCRIPT_DIR}/build-strfry.sh"
bash "${SCRIPT_DIR}/setup-strfry.sh"

# 4) Optional components
if to_bool "${DASHBOARD_ENABLED}"; then
  bash "${SCRIPT_DIR}/setup-dashboard.sh"
else
  echo "Dashboard disabled"
fi

if to_bool "${BLOSSOM_ENABLED}"; then
  bash "${SCRIPT_DIR}/setup-blossom.sh"
else
  echo "Blossom disabled"
fi

echo "All done."


