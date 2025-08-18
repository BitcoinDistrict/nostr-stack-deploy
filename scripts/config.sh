#!/usr/bin/env bash
set -euo pipefail

# Shared configuration loader and helpers

# Determine important paths
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIGS_DIR="${REPO_DIR}/configs"
RUNTIME_CONFIG_DIR="${HOME}/.strfry"
STRFRY_DIR="${REPO_DIR}/strfry"
DATA_DIR="${REPO_DIR}/strfry-db"

# Expose paths to callers
export REPO_DIR CONFIGS_DIR RUNTIME_CONFIG_DIR STRFRY_DIR DATA_DIR

# Normalize boolean-like envs (true/1/yes/on)
to_bool() {
  case "${1:-}" in
    [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Yy]|[Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac
}

# Load a dotenv-style file but do NOT override variables that are already set in the environment
# - Ignores blank lines and comments
load_env_file_preserving_existing() {
  local file="$1"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    # Strip CR (Windows endings)
    line="${line%$'\r'}"
    # Skip comments/empty lines
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # Handle KEY=VALUE pairs (allow spaces around '=')
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"
      # Trim leading spaces in value
      val="${val#*[![:space:]]}"
      # Remove optional surrounding quotes
      if [[ "$val" =~ ^"(.*)"$ ]]; then
        val="${BASH_REMATCH[1]}"
      elif [[ "$val" =~ ^'(.*)'$ ]]; then
        val="${BASH_REMATCH[1]}"
      fi
      # If not already set in environment, export it
      if [ -z "${!key+x}" ]; then
        export "$key=$val"
      fi
    fi
  done < "$file"
}

# Environment selection
# Use DEPLOY_ENV if provided (production, staging, dev, etc.)
DEPLOY_ENV="${DEPLOY_ENV:-}"
if [ -z "$DEPLOY_ENV" ] && [ "${1:-}" != "" ]; then
  DEPLOY_ENV="$1"
fi
DEPLOY_ENV="${DEPLOY_ENV:-production}"
export DEPLOY_ENV

# Load variables in priority order (lowest first), but preserve already-set envs (CI secrets win):
# 1) configs/default.env
# 2) .env (repo root, for local dev convenience)
# 3) configs/${DEPLOY_ENV}.env (e.g. production.env)
load_env_file_preserving_existing "${CONFIGS_DIR}/default.env"
load_env_file_preserving_existing "${REPO_DIR}/.env"
load_env_file_preserving_existing "${CONFIGS_DIR}/${DEPLOY_ENV}.env"

# Provide sane fallbacks if still missing after env loading
DOMAIN="${DOMAIN:-relay.example.com}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-admin@example.com}"
CLOUDFLARE_ENABLED="${CLOUDFLARE_ENABLED:-false}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"

DASHBOARD_ENABLED="${DASHBOARD_ENABLED:-false}"
DASHBOARD_DOMAIN="${DASHBOARD_DOMAIN:-dashboard.${DOMAIN}}"

BLOSSOM_ENABLED="${BLOSSOM_ENABLED:-false}"
BLOSSOM_DOMAIN="${BLOSSOM_DOMAIN:-media.${DOMAIN}}"
BLOSSOM_CONTAINER_IMAGE="${BLOSSOM_CONTAINER_IMAGE:-ghcr.io/hzrd149/blossom-server:master}"
BLOSSOM_PORT="${BLOSSOM_PORT:-3300}"
BLOSSOM_MAX_UPLOAD_MB="${BLOSSOM_MAX_UPLOAD_MB:-16}"

NOSTR_AUTH_ENABLED="${NOSTR_AUTH_ENABLED:-true}"
NOSTR_AUTH_PORT="${NOSTR_AUTH_PORT:-3310}"
NOSTR_AUTH_GATE_MODE="${NOSTR_AUTH_GATE_MODE:-nip05}"
NOSTR_AUTH_ALLOWLIST_FILE="${NOSTR_AUTH_ALLOWLIST_FILE:-}"
NOSTR_AUTH_CACHE_TTL_SECONDS="${NOSTR_AUTH_CACHE_TTL_SECONDS:-300}"
NOSTR_AUTH_LOG_LEVEL="${NOSTR_AUTH_LOG_LEVEL:-info}"

export \
  DOMAIN CERTBOT_EMAIL CLOUDFLARE_ENABLED CLOUDFLARE_API_TOKEN \
  DASHBOARD_ENABLED DASHBOARD_DOMAIN \
  BLOSSOM_ENABLED BLOSSOM_DOMAIN BLOSSOM_CONTAINER_IMAGE BLOSSOM_PORT BLOSSOM_MAX_UPLOAD_MB \
  NOSTR_AUTH_ENABLED NOSTR_AUTH_PORT NOSTR_AUTH_GATE_MODE NOSTR_AUTH_ALLOWLIST_FILE NOSTR_AUTH_CACHE_TTL_SECONDS NOSTR_AUTH_LOG_LEVEL


