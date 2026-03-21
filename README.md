# n8n on GCP Cloud Run

Deploy a production-ready [n8n](https://n8n.io) instance on Google Cloud Run with Cloud SQL (Postgres) — in one command.

## What you get

| Resource | Details |
|---|---|
| **Cloud Run** | n8n container with always-on CPU, auto-scaling |
| **Cloud SQL** | Postgres 14 — stores workflows, credentials, executions |
| **Secret Manager** | DB password + n8n encryption key (never in env vars) |
| **Service Account** | Least-privilege IAM (Cloud SQL client + secret access only) |

Data persists across container restarts because:
- All workflow/credential/execution data is stored in Postgres
- The `N8N_ENCRYPTION_KEY` is generated once and stored in Secret Manager (not on the ephemeral container filesystem)

## Prerequisites

- [Google Cloud SDK (`gcloud`)](https://cloud.google.com/sdk/docs/install) installed and authenticated
- A GCP project with billing enabled
- `bash` and `openssl` (pre-installed on macOS/Linux)

 **Note:** You do **not** need to enable any GCP APIs manually. The script automatically enables all required APIs in Phase 1:
- `sqladmin.googleapis.com` (Cloud SQL)
- `secretmanager.googleapis.com` (Secret Manager)
- `run.googleapis.com` (Cloud Run)
- `iam.googleapis.com` (IAM)

## Quick start

```bash
# 1. Clone this repo
git clone https://github.com/YOUR_USER/n8n-gcp.git
cd n8n-gcp

# 2. Copy the example env and fill in your values
cp .env.example .env
# Edit .env — at minimum set GCP_PROJECT_ID and DB_PASSWORD

# 3. Authenticate with GCP
gcloud auth login
gcloud config set project YOUR_PROJECT_ID

# 4. Deploy (all 5 phases run automatically)
./deploy.sh
```

The script is **idempotent** — safe to re-run. It skips resources that already exist.

### Quick redeploy

Changed n8n settings in `.env` (payload size, concurrency, timezone, etc.)? No need to re-run the full infrastructure setup:

```bash
./deploy.sh --redeploy
```

This skips phases 1–4 (APIs, Cloud SQL, secrets, IAM) and only updates the Cloud Run service. Your data is untouched.

## What the script does

| Phase | Action |
|---|---|
| **1** | Enable required GCP APIs (Cloud SQL, Secret Manager, Cloud Run, IAM) |
| **2** | Create Cloud SQL Postgres instance, database, and user |
| **3** | Store DB password in Secret Manager + generate & store `N8N_ENCRYPTION_KEY` |
| **4** | Create service account with least-privilege IAM bindings |
| **5** | Deploy n8n to Cloud Run with secrets injected from Secret Manager |

## Configuration

All configuration lives in `.env`. See [.env.example](.env.example) for the full list.

| Variable | Description | Default |
|---|---|---|
| `GCP_PROJECT_ID` | Your GCP project ID | — |
| `GCP_REGION` | Deployment region | `europe-west4` |
| `DB_INSTANCE_NAME` | Cloud SQL instance name | `n8n-db-instance` |
| `DB_VERSION` | Postgres version | `POSTGRES_14` |
| `DB_TIER` | Machine type ([tiers](https://cloud.google.com/sql/docs/postgres/create-instance#machine-type)) | `db-custom-1-3840` |
| `DB_NAME` | Database name | `n8n_database` |
| `DB_USER` | Database user | `n8nuser` |
| `DB_PASSWORD` | Database password (used once to seed Secret Manager) | — |
| `DB_ENABLE_BACKUPS` | Enable automated daily Cloud SQL backups | `true` |
| `CLOUD_RUN_SERVICE` | Cloud Run service name | `n8n` |
| `CLOUD_RUN_MEMORY` | Container memory | `2Gi` |
| `CLOUD_RUN_MIN_INSTANCES` | Min instances (`0` = scale to zero, `1` = always warm) | `0` |
| `CLOUD_RUN_MAX_INSTANCES` | Max instances (cost protection) | `3` |
| `N8N_VERSION` | n8n Docker image tag ([tags](https://hub.docker.com/r/n8nio/n8n/tags)) | `latest` |
| `N8N_PAYLOAD_SIZE_MAX` | Max request payload size in MB | `256` |
| `N8N_CONCURRENCY_PRODUCTION_LIMIT` | Max parallel workflow executions | `20` |
| `N8N_PROCESS_TIMEOUT` | Max execution time per workflow (ms) | `7200000` (2h) |
| `N8N_LOG_LEVEL` | Logging verbosity (`error`, `warn`, `info`, `debug`) | `info` |
| `GENERIC_TIMEZONE` | Timezone for cron/schedule triggers | `Europe/Amsterdam` |
| `SERVICE_ACCOUNT_NAME` | GCP service account name | `n8n-cloudrun-sa` |

## Security

- **No secrets in code** — passwords and keys live in GCP Secret Manager and are injected at runtime
- **Least-privilege IAM** — the service account only has `cloudsql.client` + `secretmanager.secretAccessor` (per-secret, not project-wide)
- **`.env` is gitignored** — your real credentials never leave your machine
- The n8n UI is publicly accessible by default (`--allow-unauthenticated`). For production, consider:
  - [n8n basic auth](https://docs.n8n.io/hosting/configuration/environment-variables/#security)
  - [GCP Identity-Aware Proxy (IAP)](https://cloud.google.com/iap/docs/enabling-cloud-run)

## Teardown

To remove **all** resources, use the dedicated teardown script:

```bash
./teardown.sh
```

This is a separate script (not a flag) for safety. It will:
1. Show every resource that will be deleted
2. Require you to type `DELETE` to confirm
3. Remove Cloud Run service, Cloud SQL instance, secrets, and service account

> **Warning:** This is irreversible. All workflows, credentials, and execution data will be permanently lost.

## Cost estimate

| Resource | Approximate cost |
|---|---|
| Cloud SQL (`db-custom-1-3840`, always on) | ~$35–50/month |
| Cloud Run (min-instances=0, moderate use) | ~$5–15/month |
| Secret Manager (2 secrets) | < $0.10/month |
| **Total** | **~$40–65/month** |

Setting `CLOUD_RUN_MIN_INSTANCES=1` adds ~$25/month but eliminates cold starts (better for webhook reliability).

## Upgrading Postgres

Cloud SQL supports in-place major version upgrades. Data, users, and databases are preserved automatically.

```bash
# Upgrade from Postgres 14 → 16 (recommended)
gcloud sql instances patch n8n-db-instance \
  --database-version=POSTGRES_16 \
  --project=YOUR_PROJECT_ID
```

What happens:
- GCP takes an automatic backup before the upgrade
- The instance restarts (a few minutes of downtime)
- All data is preserved
- n8n reconnects automatically (Cloud Run retries)

After upgrading, update `DB_VERSION=POSTGRES_16` in your `.env` so future full deploys use the correct version.

## License

MIT
