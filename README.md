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
│  └─ strfry.service           # Systemd service unit
└─ strfry/                     # Submodule pointing to Strfry upstream
```

---

## Setup Instructions

### 1. Server Preparation

* Ubuntu 24.04 server with a `deploy` user.
* SSH access from GitHub Actions:

  * Add private key as `DEPLOY_SSH_KEY` secret.
* Install dependencies (also handled by `deploy.sh`):

```bash
sudo apt-get update
sudo apt-get install -y build-essential cmake libsqlite3-dev libssl-dev pkg-config
```

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

* Builds Strfry from submodule.
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
sudo apt-get update
sudo apt-get install -y build-essential cmake libsqlite3-dev libssl-dev pkg-config rsync

# Clone the repo manually for first deploy (optional if using GitHub Actions)
git clone --recurse-submodules git@github.com:BitcoinDistrict/nostr-stack-deploy.git ~/nostr-stack-deploy

# Ensure configs are in place
mkdir -p ~/.strfry
cp configs/strfry.conf ~/.strfry/strfry.conf
cp configs/strfry.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable strfry
systemctl start strfry

# Verify deployment
journalctl -u strfry -f
```

---

## Notes

* Always update `<YOUR_ADMIN_NOSTR_PUBKEY>` in `strfry.conf` before deploying.
* Changes to `configs/` are version-controlled and deployed automatically.
* Submodule updates go through PR review for safety.