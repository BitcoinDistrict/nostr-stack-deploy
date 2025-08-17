#!/usr/bin/env bash
set -euo pipefail

# Generates lightweight stats JSON for the relay dashboard without touching the main relay service.
#
# Required env vars (set via systemd unit):
# - STRFRY_BIN: absolute path to strfry binary
# - DASHBOARD_ROOT: absolute path to the web root where stats.json will be written
# - NIP11_URL: base URL of the relay for fetching the NIP-11 info document

STRFRY_BIN="${STRFRY_BIN:-}"
STRFRY_CONFIG="${STRFRY_CONFIG:-}"
DASHBOARD_ROOT="${DASHBOARD_ROOT:-/var/www/relay-dashboard}"
NIP11_URL="${NIP11_URL:-}"

mkdir -p "$DASHBOARD_ROOT"
STATS_FILE="$DASHBOARD_ROOT/stats.json"
NIP11_FILE="$DASHBOARD_ROOT/nip11.json"
TMP_FILE="${STATS_FILE}.tmp"

if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  jq not found; skipping stats generation"
  exit 0
fi

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Helper to count occurrences of .kind for a time window
count_kinds() {
  local since="$1"
  # The export may be large; cap processing time with timeout.
  # If timeout is not available, it will simply run to completion.
  local cfg_arg=()
  if [ -n "$STRFRY_CONFIG" ]; then cfg_arg=("--config" "$STRFRY_CONFIG"); fi
  if command -v timeout >/dev/null 2>&1; then
    timeout 30s "$STRFRY_BIN" export "${cfg_arg[@]}" --since="$since" 2>/dev/null | jq -r '.kind' | sort | uniq -c | awk '{print $2":"$1}'
  else
    "$STRFRY_BIN" export "${cfg_arg[@]}" --since="$since" 2>/dev/null | jq -r '.kind' | sort | uniq -c | awk '{print $2":"$1}'
  fi
}

# Helper to count unique pubkeys in a time window
count_unique_pubkeys() {
  local since="$1"
  local cfg_arg=()
  if [ -n "$STRFRY_CONFIG" ]; then cfg_arg=("--config" "$STRFRY_CONFIG"); fi
  if command -v timeout >/dev/null 2>&1; then
    timeout 30s "$STRFRY_BIN" export "${cfg_arg[@]}" --since="$since" 2>/dev/null | jq -r '.pubkey' | sort -u | wc -l | tr -d ' \n'
  else
    "$STRFRY_BIN" export "${cfg_arg[@]}" --since="$since" 2>/dev/null | jq -r '.pubkey' | sort -u | wc -l | tr -d ' \n'
  fi
}

# Helper to count recent insert activity from systemd journal (best-effort)
count_inserts_since() {
  local since_human="$1"  # e.g., "5 minutes ago" or "1 hour ago"
  if ! command -v journalctl >/dev/null 2>&1; then
    echo 0
    return
  fi
  # Use UTC to avoid TZ issues, and robust date formatting for journalctl -S
  local since_iso
  if date -u -d "$since_human" +"%Y-%m-%d %H:%M:%S" >/dev/null 2>&1; then
    since_iso="$(date -u -d "$since_human" +"%Y-%m-%d %H:%M:%S")"
  else
    # Fallback to 5 minutes ago if parsing fails
    since_iso="$(date -u -d '5 minutes ago' +"%Y-%m-%d %H:%M:%S")"
  fi
  # Count lines containing the exact writer message substring
  # strfry service name is 'strfry' per configs/strfry.service
  # Grep pattern is stable across versions: "Inserted event."
  journalctl -u strfry -S "$since_iso" --no-pager 2>/dev/null \
    | grep -F "Inserted event." \
    | wc -l \
    | tr -d ' \n' || echo 0
}

# Optionally fetch NIP-11 and write to disk (avoids browser CORS issues)
if [ -n "$NIP11_URL" ] && command -v curl >/dev/null 2>&1; then
  NIP11_TMP="${NIP11_FILE}.tmp"
  if command -v timeout >/dev/null 2>&1; then
    timeout 15s curl -sSL -H 'Accept: application/nostr+json' "${NIP11_URL%/}/" -o "$NIP11_TMP" || true
  else
    curl -sSL -H 'Accept: application/nostr+json' "${NIP11_URL%/}/" -o "$NIP11_TMP" || true
  fi
  if [ -s "$NIP11_TMP" ] && jq -e . >/dev/null 2>&1 <"$NIP11_TMP"; then
    mv -f "$NIP11_TMP" "$NIP11_FILE"
  else
    rm -f "$NIP11_TMP" 2>/dev/null || true
  fi
fi

# Build JSON
generated_at="$(now_iso)"

# Events by kind for recent windows
declare -A kinds_1h kinds_24h

if [ -n "$STRFRY_BIN" ] && [ -x "$STRFRY_BIN" ]; then
  # Compute UNIX timestamps for windows
  since_1h=$(date -u -d '1 hour ago' +%s)
  since_24h=$(date -u -d '24 hours ago' +%s)

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    kind="${line%%:*}"
    count="${line##*:}"
    kinds_1h["$kind"]="$count"
  done < <(count_kinds "$since_1h")

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    kind="${line%%:*}"
    count="${line##*:}"
    kinds_24h["$kind"]="$count"
  done < <(count_kinds "$since_24h")

  # Capture output even if the pipeline exits non-zero (e.g., timeout),
  # then sanitize to a valid non-negative integer. This avoids cases like
  # "00" which would break JSON parsing.
  unique_pubkeys_24h="$(count_unique_pubkeys "$since_24h" || true)"
  if ! [[ "$unique_pubkeys_24h" =~ ^[0-9]+$ ]]; then
    unique_pubkeys_24h="0"
  fi
  # Normalize to base-10 integer to remove any leading zeros (e.g., "00" → 0)
  unique_pubkeys_24h=$((10#$unique_pubkeys_24h))
else
  unique_pubkeys_24h="0"
fi

# Serialize kind maps to JSON objects
serialize_kinds() {
  declare -n ref=$1
  printf '{'
  first=1
  for k in "${!ref[@]}"; do
    if [ $first -eq 0 ]; then printf ','; fi
    printf '"%s":%s' "$k" "${ref[$k]}"
    first=0
  done
  printf '}'
}

{
  printf '{'
  printf '"generatedAt":"%s",' "$generated_at"
  # Recent activity derived from journal (best-effort)
  inserts_5m="$(count_inserts_since '5 minutes ago')"
  inserts_1h="$(count_inserts_since '1 hour ago')"
  # Normalize to integers
  if ! [[ "$inserts_5m" =~ ^[0-9]+$ ]]; then inserts_5m=0; fi
  if ! [[ "$inserts_1h" =~ ^[0-9]+$ ]]; then inserts_1h=0; fi
  printf '"activity":{'
  printf '"insertedLast5m":%s,' "$inserts_5m"
  printf '"insertedLast1h":%s' "$inserts_1h"
  printf '},'
  printf '"lastHour":{'
  printf '"eventsByKind":'
  serialize_kinds kinds_1h
  printf '},'
  printf '"last24h":{'
  printf '"eventsByKind":'
  serialize_kinds kinds_24h
  printf ',"uniquePubkeys":%s' "$unique_pubkeys_24h"
  printf '}'
  printf '}'
} > "$TMP_FILE"

mv -f "$TMP_FILE" "$STATS_FILE"
echo "✅ Wrote stats to $STATS_FILE"


