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

## Repository Structure

```
nostr-stack-deploy/
├─ .github/workflows/
│  ├─ deploy.yml               # CI/CD deploy workflow
│  └─ auto-bump-strfry.yml     # PR workflow for upstream updates
├─ scripts/
│  └─ deploy.sh                # Server-side deploy script
├─ configs/
│  ├─ strfry.conf              # Repo-controlled Strfry config
│  ├─ strfry.service           # Systemd service unit
│  └─ nginx/                   # Nginx configuration files
│     └─ relay.bitcoindistrict.org.conf
└─ strfry/                     # Submodule pointing to Strfry upstream
```

---

## Setup Instructions

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

### 3. Configs

* `configs/strfry.conf` contains runtime configuration.
* `configs/strfry.service` defines the systemd service.
* Both are version-controlled and copied to runtime locations by `deploy.sh`.

### 4. Deploy Script (`scripts/deploy.sh`)

* Installs all required build dependencies.
* **Automatically configures swap space** for memory-constrained systems.
* **Adaptive compilation** - uses single-threaded compilation on low-memory systems (<2GB RAM).
* **Installs and configures nginx** with reverse proxy to strfry.
* **Attempts SSL certificate setup** with Let's Encrypt (requires domain to be accessible).
* Configures UFW firewall (SSH + port 7777 + HTTP/HTTPS).
* Builds Strfry from submodule with optimal settings for your system.
* Copies config to `$HOME/.strfry/strfry.conf`.
* Ensures data directory exists.
* Restarts systemd service.
* Performs a smoke test to verify binary runs with config.

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
cd ~/nostr-stack-deploy
bash scripts/deploy.sh

# Verify deployment
sudo systemctl status strfry
sudo journalctl -u strfry -f
```

---

## Notes

* Always update `<YOUR_ADMIN_NOSTR_PUBKEY>` in `strfry.conf` before deploying.
* Changes to `configs/` are version-controlled and deployed automatically.
* Submodule updates go through PR review for safety.