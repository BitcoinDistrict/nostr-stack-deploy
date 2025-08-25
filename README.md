# Nostr Stack Deploy

This repository manages automated deployment of the **Strfry Nostr Relay** for Bitcoin District. Deployment is fully automated via GitHub Actions, with submodule updates, build, configuration, and systemd service management.

---

## Architecture Overview

```text
      ┌───────────────────────────┐
      │   Upstream strfry Repo    │
      │   (new commits/releases)  │
      └─────────────┬────────────┘
                    │
                    ▼
      ┌───────────────────────────┐
      │ auto-bump-strfry.yml      │
      │ GitHub Actions Workflow   │
      │ - Checks for upstream     │
      │   commits on strfry/main │
      │ - Builds submodule        │
      │ - Runs runtime sanity     │
      │   check (--version/--help)│
      │ - Opens a PR if successful│
      └─────────────┬────────────┘
                    │ PR created
                    ▼
      ┌───────────────────────────┐
      │ Manual Review & Merge PR  │
      │ - Human confirms build    │
      │   + sanity checks pass   │
      └─────────────┬────────────┘
                    │ Merge to main
                    ▼
      ┌───────────────────────────┐
      │ deploy.yml                │
      │ GitHub Actions Workflow   │
      │ - Checkout repo & submodules
      │ - SSH to server           │
      │ - Run deploy.sh           │
      │   • Build strfry          │
      │   • Copy runtime config   │
      │   • Restart systemd       │
      │ - Smoke test with config  │
      └─────────────┬────────────┘
                    │ Success → Production
                    ▼
      ┌───────────────────────────┐
      │ Live strfry Relay         │
      │ - Running with deployed   │
      │   repo-controlled config  │
      │ - Systemd ensures restart │
      │   on failure              │
      └───────────────────────────┘
```

---

### Strfry event gating vs Blossom upload authentication

- **Strfry (relay) uses `plugins/nip05_gate.py`** to accept/reject incoming events.
  - **What it does**: Builds an allowlist from one or more `.well-known/nostr.json` documents and accepts events whose `pubkey` is present in `names`, `verified_names`, or both (configurable).
  - **Behavior**:
    - Non-blocking event path; background refresh with per-URL backoff and conditional HTTP (ETag/Last-Modified; 304 treated as success).
    - Optional startup fail-open for regular kinds via `--startup-grace-seconds` (ephemeral kinds remain rate-limited).
    - Ephemeral kinds `20000–29999` are governed by per-pubkey token buckets (`EPHEMERAL_*`), independent of the allowlist.
    - Optional bypass for `Import/Sync/Stream` sources when `--allow-import` is enabled.
  - **Key flags/env**: `NIP05_JSON_URLS`/`NIP05_JSON_URL`, `NIP05_FIELD` (`names|verified_names|both`), `ALLOW_IMPORT`, `STARTUP_GRACE_SECONDS`, `EPHEMERAL_RATE`, `EPHEMERAL_BURST`, `EPHEMERAL_MAX_BUCKETS`, `EPHEMERAL_TTL_SECONDS`.
  - **Scope**: Only affects the relay’s event ingestion; does not interact with the auth proxy.

- **Blossom (media uploads) uses `scripts/nostr-auth-proxy/`**, not the strfry plugin.
  - **What it does**: Validates upload requests in front of Blossom using NIP‑98 (or legacy 24242) and NIP‑05 mapping, with modes `nip05` (default), `allowlist`, or `open`.
  - **Key env**: `GATE_MODE`, `ALLOWLIST_FILE`, `REQUIRED_NIP05_DOMAIN`, plus timing/cache knobs like `CACHE_TTL` and `SKEW_SECONDS`.
  - **Scope**: Only affects Blossom upload routes (via nginx `auth_request`); does not affect relay events.

In short: the relay is gated by `nip05_gate.py`, and the media server is gated by `nostr-auth-proxy`. They are independent and can run side‑by‑side when both services are enabled.

## Repository Structure

```
nostr-stack-deploy/
├─ .github/workflows/
│  ├─ deploy.yml               # CI/CD deploy workflow
│  └─ auto-bump-strfry.yml     # PR workflow for upstream updates
├─ scripts/
│  └─ deploy.sh                # Server-side deploy script
│  └─ dashboard/               # Stats generation scripts
│     └─ generate_stats.sh
├─ configs/
│  ├─ strfry.conf              # Repo-controlled Strfry config
│  ├─ strfry.service           # Systemd service unit
│  └─ nginx/                   # Nginx configuration files
│     └─ relay.bitcoindistrict.org.conf
│  └─ dashboard/               # Dashboard units and env
│     ├─ dashboard.env
│     ├─ relay-dashboard.service
│     ├─ relay-dashboard-stats.service
│     └─ relay-dashboard-stats.timer
├─ web/
│  └─ relay-dashboard/         # Static dashboard frontend
│     └─ index.html
└─ strfry/                     # Submodule pointing to Strfry upstream
```

---

## Setup Instructions

This repo now uses modular scripts and environment files.

### Environment configuration

- Copy `configs/default.env` to `.env` (optional for local/dev) and adjust.
- For environment-specific overrides, create `configs/production.env`, `configs/staging.env`, etc.
- Secrets (API tokens, SSH keys) should be provided via CI/CD secrets or host environment and not committed.

Priority when loading variables:

1. `configs/default.env`
2. `.env` in repo root
3. `configs/${DEPLOY_ENV}.env`
4. Variables injected by the environment (CI secrets) override all

### Scripts

- `scripts/deploy.sh`: Orchestrator. Loads config, then calls modules.
- `scripts/setup-system.sh`: Base packages, swap, firewall.
- `scripts/setup-nginx.sh`: Nginx and certificates for the relay `${DOMAIN}`.
- `scripts/build-strfry.sh`: Builds strfry with sensible parallelism.
- `scripts/setup-strfry.sh`: Installs runtime config and systemd service for strfry.
- `scripts/setup-dashboard.sh`: Optional dashboard (gated by `DASHBOARD_ENABLED`).
- `scripts/setup-blossom.sh`: Optional Blossom + nostr-auth-proxy (gated by `BLOSSOM_ENABLED`).
- `scripts/deploy_legacy.sh`: Previous monolithic script retained for fallback.

### Nginx templates

Templates live in `configs/nginx/*.template` and are rendered with `envsubst` at deploy time.

### CI/CD

The GitHub Actions workflow `deploy.yml` invokes the orchestrator and passes variables/secrets from repository settings. Set `vars.DEPLOY_ENV` to select `configs/${DEPLOY_ENV}.env`.

### 1. Server Preparation

* Ubuntu 24.04 server with a `deploy` user.
* SSH access from GitHub Actions:

  * Add private key as `DEPLOY_SSH_KEY` secret.
* Install dependencies (automatically handled by `deploy.sh`):

```bash
sudo apt-get update
sudo apt-get install -y build-essential libsqlite3-dev libssl-dev pkg-config \
    liblmdb-dev libflatbuffers-dev libsecp256k1-dev libzstd-dev zlib1g-dev
```

### 1.1 System Requirements

**Minimum Requirements:**
- **RAM**: 1GB (with automatic swap space configuration)
- **Storage**: 20GB+ (for OS, dependencies, and strfry database)
- **CPU**: 1 vCPU (compilation will be single-threaded)

**Recommended Requirements:**
- **RAM**: 2GB+ (enables parallel compilation)
- **Storage**: 40GB+ (for larger databases and future growth)
- **CPU**: 2+ vCPUs (faster compilation and better performance)

**Performance Notes:**
- 1GB RAM droplets will use single-threaded compilation (slower but reliable)
- 2GB+ RAM droplets will use parallel compilation (faster build)
- The deploy script automatically optimizes for your system's capabilities

### 2. GitHub Secrets

| Secret Name      | Description                     |
| ---------------- | ------------------------------- |
| DEPLOY\_HOST     | Server hostname or IP           |
| DEPLOY\_USER     | Deploy username                 |
| DEPLOY\_SSH\_KEY | Private SSH key for deploy user |
| GITHUB\_TOKEN    | Default GitHub Actions token    |
| CLOUDFLARE\_API\_TOKEN | Cloudflare API token for DNS-01 (optional) |

### 3. Configs

* `configs/strfry.conf` contains runtime configuration.
* `configs/strfry.service` defines the systemd service.
* Both are version-controlled and copied to runtime locations by `deploy.sh`.

### 4. Deploy Script (`scripts/deploy.sh`)

* Installs all required build dependencies.
* **Automatically configures swap space** for memory-constrained systems.
* **Adaptive compilation** - uses single-threaded compilation on low-memory systems (<2GB RAM).
* **Installs and configures nginx** with reverse proxy to strfry.
* **Obtains SSL certificates with Let's Encrypt** using either:
  - HTTP-01 via the Nginx plugin (default), or
  - DNS-01 via Cloudflare (when enabled), which works with proxied orange-cloud records.
* Configures UFW firewall (SSH + port 7777 + HTTP/HTTPS).
* Builds Strfry from submodule with optimal settings for your system.
* Copies config to `$HOME/.strfry/strfry.conf`.
* Ensures data directory exists.
* Restarts systemd service.
* Performs a smoke test to verify binary runs with config.
* Optionally deploys a modular dashboard (NIP-11 + lightweight stats) served as static files behind nginx. Controlled via env.

### 4.1 Deploy Configuration (Environment Variables)

You can customize the deployment via environment variables found in `configs/default.env`

Guidance:
- Put SECRETS (e.g., `CLOUDFLARE_API_TOKEN`, SSH keys) in your CI/CD secrets or host environment. Do not commit them.
- Put non-secret SETTINGS in a `.env` file on the server or export before running `scripts/deploy.sh`. You can base this on `configs/env.example`.
- Repo-controlled configs live in `configs/` and are safe to commit (e.g., nginx vhost templates, systemd unit files, blossom config template). Runtime copies are written to `/etc/...` by the deploy script.

- `DOMAIN`: Relay FQDN. Must resolve to the server.
- `CERTBOT_EMAIL`: Email used for Let's Encrypt registration/alerts.
- `CLOUDFLARE_ENABLED`: Set `true` to use Certbot's Cloudflare DNS plugin (DNS-01).
- `CLOUDFLARE_API_TOKEN`: Cloudflare API token with Zone DNS Edit permissions.
- `DASHBOARD_ENABLED`: When `true`, installs static dashboard and timer to generate stats JSON.
- `DASHBOARD_DOMAIN`: FQDN for the dashboard vhost.

When the dashboard is enabled, the following are installed without touching the main relay service:

- Static files to `/var/www/relay-dashboard`.
- Separate Nginx vhost for `DASHBOARD_DOMAIN` (HTTP → HTTPS redirect; serves only static files).
- Systemd units: `relay-dashboard.service` (provisions webroot) and `relay-dashboard-stats.timer`/`.service` (refreshes `stats.json` and cached `nip11.json`).
- Env file at `configs/dashboard/dashboard.env` allows overriding `STRFRY_BIN`, `STRFRY_CONFIG`, `DASHBOARD_ROOT`, `NIP11_URL`.

When Cloudflare is enabled, certificates are issued via DNS-01 and work with proxied (orange-cloud) DNS records. Otherwise, HTTP-01 is used via the Nginx plugin.

### 5. Workflows

* **auto-bump-strfry.yml**

  * Checks upstream `strfry` repo for updates.
  * Runs build and runtime checks.
  * Opens a PR if the submodule can be safely updated.
* **deploy.yml**

  * Triggered on `main` push.
  * Syncs repo to server and runs `deploy.sh`.
  * Smoke test confirms deployment success.

---

## Quickstart: Deploy on a Bare Server

```bash
# On your server:
adduser deploy
usermod -aG sudo deploy
mkdir -p ~/nostr-stack-deploy

# Clone the repo manually for first deploy (optional if using GitHub Actions)
git clone --recurse-submodules git@github.com:BitcoinDistrict/nostr-stack-deploy.git ~/nostr-stack-deploy

# Run the automated deployment script
# Optionally set environment variables inline
cd ~/nostr-stack-deploy
DOMAIN=relay.bitcoindistrict.org \
CERTBOT_EMAIL=you@example.com \
CLOUDFLARE_ENABLED=true \
CLOUDFLARE_API_TOKEN=cf_XXXXXXXXXXXXXXXXXXXXXXXXXXXX \
DASHBOARD_ENABLED=true \
DASHBOARD_DOMAIN=dashboard.relay.bitcoindistrict.org \
bash scripts/deploy.sh

# Verify deployment
sudo systemctl status strfry
sudo journalctl -u strfry -f
```

---

## Blossom Media Server Integration (Plan)

We will add a Blossom media server to the stack to handle blob storage (images/files) using the upstream implementation. Reference: [hzrd149/blossom-server](https://github.com/hzrd149/blossom-server).

### What we'll add

- Service `blossom-server` on the relay host (containerized by default for reproducibility).
- Repo-controlled config at `configs/blossom/config.yml`.
- Systemd unit `configs/blossom/blossom.service` to manage the service.
- Nginx vhost for `BLOSSOM_DOMAIN` with TLS and reverse proxy to localhost.
- Upload gating: Only NIP‑05 verified pubkeys may upload; reads remain public.

### Deployment toggles (Environment Variables)

```
BLOSSOM_ENABLED=true
BLOSSOM_DOMAIN=media.relay.bitcoindistrict.org
BLOSSOM_CONTAINER_IMAGE=ghcr.io/hzrd149/blossom-server:master
BLOSSOM_PORT=3300
BLOSSOM_MAX_UPLOAD_MB=16
BLOSSOM_GATE_MODE=nip05   # nip05 | allowlist | open
BLOSSOM_ALLOWLIST_FILE=/etc/blossom/allowlist.txt
```

Notes:
- Certificates are issued the same way as the relay (HTTP‑01 or Cloudflare DNS‑01).
- `BLOSSOM_PORT` listens on `127.0.0.1`; nginx handles public TLS on `BLOSSOM_DOMAIN`.
- A non-container option (Node under systemd using npx) will be supported via a flag; container is default.

### NIP‑05 gate (uploads)

We will enforce uploads from Nostr verified pubkeys via an auth proxy in front of Blossom:

- Require NIP‑98 signed requests to authenticate the uploader's pubkey.
- Require header `X-NIP05: <name@domain>`; resolve and verify `.well-known/nostr.json` maps to the authenticated pubkey.
- Implemented as a minimal auth service; nginx uses `auth_request` on upload routes. Modes:
  - `nip05` (default): full NIP‑98 + NIP‑05 validation.
  - `allowlist`: only pubkeys in `BLOSSOM_ALLOWLIST_FILE` may upload.
  - `open`: no gate (not recommended).

Downloads remain public.

### Files to be added

- `configs/blossom/config.yml`: Base server config (data dir `/var/lib/blossom`, base URL `https://${BLOSSOM_DOMAIN}`, limits from env).
- `configs/blossom/blossom.service`: Systemd unit (container or node mode) with persistent data volume.
- `configs/nginx/${BLOSSOM_DOMAIN}.conf`: Nginx vhost with TLS, caching headers, gzip, proxy to `127.0.0.1:${BLOSSOM_PORT}`; `auth_request` on upload endpoints when gated.
- `scripts/nostr-auth-proxy/`: Minimal service validating NIP‑98 and NIP‑05; returns 2xx/4xx for nginx `auth_request`.
- `scripts/deploy.sh`: Add gated provisioning behind `BLOSSOM_ENABLED`.

### Client upload example (preview)

```bash
curl -X POST \
  -H "Authorization: Nostr <nip98-signed-event>" \
  -H "X-NIP05: alice@example.com" \
  -F "file=@/path/to/image.jpg" \
  https://$BLOSSOM_DOMAIN/upload
```

### Gate Modes

The auth proxy supports three gate modes:

- **`nip05`** (default): Requires NIP-98 signed requests and validates NIP-05 mapping
- **`allowlist`**: Only allows pubkeys listed in `NOSTR_AUTH_ALLOWLIST_FILE` 
- **`open`**: No authentication required (not recommended for production)

The deploy script automatically configures volume mounts only when using `allowlist` mode, avoiding invalid Docker mount specifications.

Consult upstream docs for exact endpoints and config: [hzrd149/blossom-server](https://github.com/hzrd149/blossom-server).

NIP‑98 reference: kind 27235 events with empty content, `u` (absolute URL) and `method` tags must be signed, and `created_at` must be within a short window (default 60s). The proxy enforces these checks and validates NIP‑05 mapping before allowing uploads. See spec: [NIP‑98](https://nostr-nips.com/nip-98).

### Where to put variables and secrets

- Secrets:
  - `CLOUDFLARE_API_TOKEN`, SSH keys: store as GitHub Actions secrets or server env vars. Never commit.
- Non-secrets (safe in `.env` on the server):
  - `DOMAIN`, `CERTBOT_EMAIL`, `DASHBOARD_*`, `BLOSSOM_*`, `NOSTR_AUTH_*`.
- Files managed by deploy script:
  - `/etc/blossom/config.yml` and `/etc/default/*` are generated from `configs/` and env values.

### Rollout plan

1. Commit new config, systemd unit, nginx vhost, and auth proxy; guard with `BLOSSOM_ENABLED`.
2. Extend `deploy.sh` to provision Docker (if needed), install files, obtain certs, start services, and smoke‑test.
3. Stage with `BLOSSOM_GATE_MODE=allowlist` and verify uploads/reads end‑to‑end.
4. Switch to `BLOSSOM_GATE_MODE=nip05` and validate NIP‑98/NIP‑05 flow.
5. Enable in production.

---

## Notes

* Always update `<YOUR_ADMIN_NOSTR_PUBKEY>` in `strfry.conf` before deploying.
* Changes to `configs/` are version-controlled and deployed automatically.
* Submodule updates go through PR review for safety.