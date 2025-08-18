#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh" "${DEPLOY_ENV:-}"

mkdir -p "${RUNTIME_CONFIG_DIR}"
cd "${STRFRY_DIR}"

BUILD_STATE_FILE="${RUNTIME_CONFIG_DIR}/strfry_build.sha"
if [ -f ".commit" ]; then
  CURRENT_SUBMODULE_SHA="$(tr -d '\r\n' < .commit || echo unknown)"
else
  CURRENT_SUBMODULE_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
fi

# Decide parallelism based on memory
TOTAL_MEM=$(free -m | awk 'NR==2{printf "%.0f", $2}')
if [ "$TOTAL_MEM" -lt 2048 ]; then
  MAKE_JOBS=1
else
  CPU_CORES=$(nproc)
  if [ "$TOTAL_MEM" -lt 4096 ]; then
    MAKE_JOBS=$((CPU_CORES / 2))
  else
    MAKE_JOBS=$CPU_CORES
  fi
fi

if [ -x "strfry" ] && [ -f "$BUILD_STATE_FILE" ] && grep -qx "$CURRENT_SUBMODULE_SHA" "$BUILD_STATE_FILE"; then
  echo "strfry already built for $CURRENT_SUBMODULE_SHA"
else
  if [ -x "strfry" ] && [ "$CURRENT_SUBMODULE_SHA" = "unknown" ]; then
    echo "strfry present; skipping build (unknown commit)"
  else
    [ -d build ] && rm -rf build/
    git submodule update --init
    make setup-golpe
    make -j"${MAKE_JOBS}"
  fi
  if [ "$CURRENT_SUBMODULE_SHA" != "unknown" ]; then
    echo "$CURRENT_SUBMODULE_SHA" > "$BUILD_STATE_FILE"
  fi
fi


