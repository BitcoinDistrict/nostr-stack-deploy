#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh" "${DEPLOY_ENV:-}"

mkdir -p "${RUNTIME_CONFIG_DIR}"
cp "${CONFIGS_DIR}/strfry.conf" "${RUNTIME_CONFIG_DIR}/strfry.conf"

chmod +x "${REPO_DIR}/plugins/nip05_gate.py"
mkdir -p "${DATA_DIR}"

# Write /etc/default/strfry so plugin envs are available to the service
sudo mkdir -p /etc/default
cat <<EOF | sudo tee /etc/default/strfry >/dev/null
STRFRY_CONFIG=${RUNTIME_CONFIG_DIR}/strfry.conf
NIP05_JSON_URLS=${NIP05_JSON_URLS:-}
NIP05_CACHE_TTL=${NIP05_CACHE_TTL:-300}
ALLOW_IMPORT=${ALLOW_IMPORT:-false}
EOF

sudo cp "${CONFIGS_DIR}/strfry.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable strfry
sudo systemctl restart strfry

"${STRFRY_DIR}/strfry" --config "${RUNTIME_CONFIG_DIR}/strfry.conf" --version || \
"${STRFRY_DIR}/strfry" --config "${RUNTIME_CONFIG_DIR}/strfry.conf" --help


