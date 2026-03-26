#!/usr/bin/env bash
# ============================================================
# n8n on GCP Cloud Run — Queue Mode Deployment
# ============================================================
# Deploys n8n in queue mode: Main (UI + webhooks) + Workers
# connected via Redis (Cloud Memorystore).
#
# Usage:  ./deploy-queue.sh              # full deploy (all 7 phases)
#         ./deploy-queue.sh --redeploy   # update Cloud Run services only
# Config: .env (copy from .env.queue.example)
# ============================================================
set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

phase()  { echo -e "\n${CYAN}━━━ Phase $1: $2 ━━━${NC}\n"; }
info()   { echo -e "${GREEN}✔ $1${NC}"; }
warn()   { echo -e "${YELLOW}⚠ $1${NC}"; }
fail()   { echo -e "${RED}✖ $1${NC}"; exit 1; }

# ── Parse flags ──────────────────────────────────────────────
REDEPLOY_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --redeploy) REDEPLOY_ONLY=true ;;
    --help|-h)
      echo "Usage: ./deploy-queue.sh [--redeploy]"
      echo "  --redeploy  Skip infrastructure (phases 1-5), only update Cloud Run services"
      exit 0 ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# ── Load .env ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  fail ".env file not found. Copy .env.queue.example to .env and fill in your values."
fi

set -a
# shellcheck source=.env
source "$ENV_FILE"
set +a

# Validate required vars
for var in GCP_PROJECT_ID GCP_REGION DB_INSTANCE_NAME DB_VERSION DB_TIER \
           DB_NAME DB_USER DB_PASSWORD SECRET_DB_PASSWORD SECRET_ENCRYPTION_KEY \
           CLOUD_RUN_SERVICE CLOUD_RUN_MEMORY CLOUD_RUN_PORT SERVICE_ACCOUNT_NAME \
           WORKER_SERVICE WORKER_MEMORY WORKER_CONCURRENCY \
           REDIS_INSTANCE_NAME REDIS_TIER REDIS_SIZE_GB REDIS_VERSION \
           VPC_CONNECTOR_NAME VPC_CONNECTOR_RANGE; do
  if [[ -z "${!var:-}" ]]; then
    fail "Required variable ${var} is not set in .env"
  fi
done

if [[ "$DB_PASSWORD" == "CHANGE_ME_BEFORE_RUNNING" ]]; then
  fail "You must set a real DB_PASSWORD in .env before running this script."
fi

# Derived values
SA_EMAIL="${SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
CONNECTION_NAME="${GCP_PROJECT_ID}:${GCP_REGION}:${DB_INSTANCE_NAME}"
MIN_INSTANCES="${CLOUD_RUN_MIN_INSTANCES:-1}"
MAX_INSTANCES="${CLOUD_RUN_MAX_INSTANCES:-2}"
WORKER_MIN="${WORKER_MIN_INSTANCES:-1}"
WORKER_MAX="${WORKER_MAX_INSTANCES:-5}"
N8N_IMAGE="n8nio/n8n:${N8N_VERSION:-latest}"

echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         n8n Queue Mode Deployment                ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo -e "${CYAN}Project:      ${NC}${GCP_PROJECT_ID}"
echo -e "${CYAN}Region:       ${NC}${GCP_REGION}"
echo -e "${CYAN}Main service: ${NC}${CLOUD_RUN_SERVICE}"
echo -e "${CYAN}Worker svc:   ${NC}${WORKER_SERVICE}"
echo -e "${CYAN}Redis:        ${NC}${REDIS_INSTANCE_NAME}"
echo -e "${CYAN}n8n Image:    ${NC}${N8N_IMAGE}"
echo -e "${CYAN}SA Email:     ${NC}${SA_EMAIL}"

if $REDEPLOY_ONLY; then
  warn "--redeploy: skipping phases 1-5, jumping to Cloud Run deploy"
else

# ═════════════════════════════════════════════════════════════
# PHASE 1: Enable GCP APIs
# ═════════════════════════════════════════════════════════════
phase 1 "Enable GCP APIs"

APIS=(
  sqladmin.googleapis.com
  secretmanager.googleapis.com
  run.googleapis.com
  iam.googleapis.com
  redis.googleapis.com
  vpcaccess.googleapis.com
  compute.googleapis.com
)

gcloud services enable "${APIS[@]}" --project="$GCP_PROJECT_ID"
info "All required APIs enabled."

# ═════════════════════════════════════════════════════════════
# PHASE 2: Cloud SQL (Postgres)
# ═════════════════════════════════════════════════════════════
phase 2 "Cloud SQL — Postgres Instance, Database & User"

# 2a. Create instance
if gcloud sql instances describe "$DB_INSTANCE_NAME" --project="$GCP_PROJECT_ID" &>/dev/null; then
  info "Cloud SQL instance '${DB_INSTANCE_NAME}' already exists — skipping."
else
  echo "Creating Cloud SQL instance '${DB_INSTANCE_NAME}' (this takes a few minutes)…"
  gcloud sql instances create "$DB_INSTANCE_NAME" \
    --database-version="$DB_VERSION" \
    --region="$GCP_REGION" \
    --tier="$DB_TIER" \
    --project="$GCP_PROJECT_ID" \
    --database-flags=cloudsql.iam_authentication=Off
  info "Cloud SQL instance created."
fi

# 2b. Automated backups
if [[ "${DB_ENABLE_BACKUPS:-true}" == "true" ]]; then
  gcloud sql instances patch "$DB_INSTANCE_NAME" \
    --backup-start-time="03:00" \
    --enable-bin-log \
    --project="$GCP_PROJECT_ID" \
    --quiet 2>/dev/null || true
  info "Automated daily backups enabled (03:00 UTC, 7-day retention)."
else
  warn "Backups disabled (DB_ENABLE_BACKUPS=false). Not recommended for production."
fi

# 2c. Create database
if gcloud sql databases describe "$DB_NAME" --instance="$DB_INSTANCE_NAME" --project="$GCP_PROJECT_ID" &>/dev/null; then
  info "Database '${DB_NAME}' already exists — skipping."
else
  gcloud sql databases create "$DB_NAME" \
    --instance="$DB_INSTANCE_NAME" \
    --project="$GCP_PROJECT_ID"
  info "Database '${DB_NAME}' created."
fi

# 2d. Create user
if gcloud sql users list --instance="$DB_INSTANCE_NAME" --project="$GCP_PROJECT_ID" \
    --format="value(name)" | grep -qx "$DB_USER"; then
  info "User '${DB_USER}' already exists — skipping."
else
  gcloud sql users create "$DB_USER" \
    --instance="$DB_INSTANCE_NAME" \
    --password="$DB_PASSWORD" \
    --project="$GCP_PROJECT_ID"
  info "User '${DB_USER}' created."
fi

# ═════════════════════════════════════════════════════════════
# PHASE 3: Secret Manager
# ═════════════════════════════════════════════════════════════
phase 3 "Secret Manager — DB Password & Encryption Key"

# DB password
if gcloud secrets describe "$SECRET_DB_PASSWORD" --project="$GCP_PROJECT_ID" &>/dev/null; then
  info "Secret '${SECRET_DB_PASSWORD}' already exists — skipping."
else
  printf '%s' "$DB_PASSWORD" | gcloud secrets create "$SECRET_DB_PASSWORD" \
    --data-file=- \
    --replication-policy=automatic \
    --project="$GCP_PROJECT_ID"
  info "Secret '${SECRET_DB_PASSWORD}' created."
fi

# Encryption key
if gcloud secrets describe "$SECRET_ENCRYPTION_KEY" --project="$GCP_PROJECT_ID" &>/dev/null; then
  info "Secret '${SECRET_ENCRYPTION_KEY}' already exists — skipping."
else
  ENCRYPTION_KEY=$(openssl rand -hex 32)
  printf '%s' "$ENCRYPTION_KEY" | gcloud secrets create "$SECRET_ENCRYPTION_KEY" \
    --data-file=- \
    --replication-policy=automatic \
    --project="$GCP_PROJECT_ID"
  info "Secret '${SECRET_ENCRYPTION_KEY}' created (encryption key generated)."
fi

# ═════════════════════════════════════════════════════════════
# PHASE 4: Redis (Cloud Memorystore)
# ═════════════════════════════════════════════════════════════
phase 4 "Redis — Cloud Memorystore for Job Queue"

if gcloud redis instances describe "$REDIS_INSTANCE_NAME" \
    --region="$GCP_REGION" --project="$GCP_PROJECT_ID" &>/dev/null; then
  info "Redis instance '${REDIS_INSTANCE_NAME}' already exists — skipping."
else
  echo "Creating Redis instance '${REDIS_INSTANCE_NAME}' (this takes a few minutes)…"
  gcloud redis instances create "$REDIS_INSTANCE_NAME" \
    --size="$REDIS_SIZE_GB" \
    --region="$GCP_REGION" \
    --tier="$REDIS_TIER" \
    --redis-version="$REDIS_VERSION" \
    --project="$GCP_PROJECT_ID"
  info "Redis instance '${REDIS_INSTANCE_NAME}' created."
fi

# Get Redis host IP
REDIS_HOST=$(gcloud redis instances describe "$REDIS_INSTANCE_NAME" \
  --region="$GCP_REGION" \
  --project="$GCP_PROJECT_ID" \
  --format="value(host)")
REDIS_PORT=$(gcloud redis instances describe "$REDIS_INSTANCE_NAME" \
  --region="$GCP_REGION" \
  --project="$GCP_PROJECT_ID" \
  --format="value(port)")
info "Redis endpoint: ${REDIS_HOST}:${REDIS_PORT}"

# ═════════════════════════════════════════════════════════════
# PHASE 5: VPC Connector + Service Account & IAM
# ═════════════════════════════════════════════════════════════
phase 5 "VPC Connector, Service Account & IAM"

# 5a. VPC Connector (Cloud Run needs this to reach Memorystore)
if gcloud compute networks vpc-access connectors describe "$VPC_CONNECTOR_NAME" \
    --region="$GCP_REGION" --project="$GCP_PROJECT_ID" &>/dev/null; then
  info "VPC connector '${VPC_CONNECTOR_NAME}' already exists — skipping."
else
  echo "Creating VPC connector '${VPC_CONNECTOR_NAME}'…"
  gcloud compute networks vpc-access connectors create "$VPC_CONNECTOR_NAME" \
    --region="$GCP_REGION" \
    --range="$VPC_CONNECTOR_RANGE" \
    --project="$GCP_PROJECT_ID"
  info "VPC connector '${VPC_CONNECTOR_NAME}' created."
fi

# 5b. Service account
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$GCP_PROJECT_ID" &>/dev/null; then
  info "Service account '${SERVICE_ACCOUNT_NAME}' already exists — skipping."
else
  gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
    --display-name="Service Account for n8n Cloud Run (Queue Mode)" \
    --project="$GCP_PROJECT_ID"
  info "Service account '${SERVICE_ACCOUNT_NAME}' created."
fi

# 5c. IAM bindings
gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/cloudsql.client" \
  --condition=None \
  --quiet
info "Granted roles/cloudsql.client."

gcloud secrets add-iam-policy-binding "$SECRET_DB_PASSWORD" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --project="$GCP_PROJECT_ID" \
  --quiet
info "Granted secretAccessor on '${SECRET_DB_PASSWORD}'."

gcloud secrets add-iam-policy-binding "$SECRET_ENCRYPTION_KEY" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --project="$GCP_PROJECT_ID" \
  --quiet
info "Granted secretAccessor on '${SECRET_ENCRYPTION_KEY}'."

fi  # end of REDEPLOY_ONLY skip

# ── Fetch Redis IP (needed for both full deploy and redeploy) ──
if [[ -z "${REDIS_HOST:-}" ]]; then
  REDIS_HOST=$(gcloud redis instances describe "$REDIS_INSTANCE_NAME" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT_ID" \
    --format="value(host)")
  REDIS_PORT=$(gcloud redis instances describe "$REDIS_INSTANCE_NAME" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT_ID" \
    --format="value(port)")
fi

# ── Shared env vars for both main and workers ──
SHARED_ENV_VARS="\
DB_TYPE=postgresdb,\
DB_POSTGRESDB_HOST=/cloudsql/${CONNECTION_NAME},\
DB_POSTGRESDB_DATABASE=${DB_NAME},\
DB_POSTGRESDB_USER=${DB_USER},\
DB_POSTGRESDB_PORT=5432,\
EXECUTIONS_MODE=queue,\
QUEUE_BULL_REDIS_HOST=${REDIS_HOST},\
QUEUE_BULL_REDIS_PORT=${REDIS_PORT},\
EXECUTIONS_DATA_SAVE_ON_ERROR=all,\
EXECUTIONS_DATA_SAVE_ON_SUCCESS=all,\
N8N_DIAGNOSTICS_ENABLED=false,\
N8N_PAYLOAD_SIZE_MAX=${N8N_PAYLOAD_SIZE_MAX:-256},\
N8N_PROCESS_TIMEOUT=${N8N_PROCESS_TIMEOUT:-7200000},\
N8N_LOG_LEVEL=${N8N_LOG_LEVEL:-info},\
GENERIC_TIMEZONE=${GENERIC_TIMEZONE:-Europe/Amsterdam}"

SHARED_SECRETS="\
DB_POSTGRESDB_PASSWORD=${SECRET_DB_PASSWORD}:latest,\
N8N_ENCRYPTION_KEY=${SECRET_ENCRYPTION_KEY}:latest"

# ═════════════════════════════════════════════════════════════
# PHASE 6: Deploy Main (UI + Webhooks)
# ═════════════════════════════════════════════════════════════
phase 6 "Deploy n8n Main (UI + Webhooks)"

# Auto-detect WEBHOOK_URL from existing deployment
MAIN_URL=$(gcloud run services describe "$CLOUD_RUN_SERVICE" \
  --region="$GCP_REGION" \
  --project="$GCP_PROJECT_ID" \
  --format="value(status.url)" 2>/dev/null || true)

gcloud run deploy "$CLOUD_RUN_SERVICE" \
  --image="$N8N_IMAGE" \
  --region="$GCP_REGION" \
  --project="$GCP_PROJECT_ID" \
  --allow-unauthenticated \
  --port="$CLOUD_RUN_PORT" \
  --no-cpu-throttling \
  --memory="$CLOUD_RUN_MEMORY" \
  --min-instances="$MIN_INSTANCES" \
  --max-instances="$MAX_INSTANCES" \
  --service-account="$SA_EMAIL" \
  --add-cloudsql-instances="$CONNECTION_NAME" \
  --vpc-connector="$VPC_CONNECTOR_NAME" \
  --set-env-vars="${SHARED_ENV_VARS},\
N8N_ENDPOINT_HEALTH=health,\
N8N_PROXY_HOPS=${N8N_PROXY_HOPS:-1},\
WEBHOOK_URL=${MAIN_URL:-}" \
  --set-secrets="$SHARED_SECRETS"

info "Main service '${CLOUD_RUN_SERVICE}' deployed."

# ═════════════════════════════════════════════════════════════
# PHASE 7: Deploy Workers
# ═════════════════════════════════════════════════════════════
phase 7 "Deploy n8n Workers"

gcloud run deploy "$WORKER_SERVICE" \
  --image="$N8N_IMAGE" \
  --region="$GCP_REGION" \
  --project="$GCP_PROJECT_ID" \
  --no-allow-unauthenticated \
  --port="$CLOUD_RUN_PORT" \
  --no-cpu-throttling \
  --memory="$WORKER_MEMORY" \
  --min-instances="$WORKER_MIN" \
  --max-instances="$WORKER_MAX" \
  --service-account="$SA_EMAIL" \
  --add-cloudsql-instances="$CONNECTION_NAME" \
  --vpc-connector="$VPC_CONNECTOR_NAME" \
  --command="n8n" \
  --args="worker","--concurrency=${WORKER_CONCURRENCY:-10}" \
  --set-env-vars="$SHARED_ENV_VARS" \
  --set-secrets="$SHARED_SECRETS"

info "Worker service '${WORKER_SERVICE}' deployed."

# ── Print result ─────────────────────────────────────────────
GCP_PROJECT_NUMBER=$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(projectNumber)" 2>/dev/null || true)
if [[ -n "$GCP_PROJECT_NUMBER" ]]; then
  MAIN_URL="https://${CLOUD_RUN_SERVICE}-${GCP_PROJECT_NUMBER}.${GCP_REGION}.run.app"
else
  MAIN_URL=$(gcloud run services describe "$CLOUD_RUN_SERVICE" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT_ID" \
    --format="value(status.url)")
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  n8n Queue Mode deployed!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYAN}Main (UI):   ${NC}${MAIN_URL}"
echo -e "  ${CYAN}Health:      ${NC}${MAIN_URL}/health"
echo -e "  ${CYAN}Workers:     ${NC}${WORKER_SERVICE} (${WORKER_MIN}-${WORKER_MAX} instances)"
echo -e "  ${CYAN}Redis:       ${NC}${REDIS_HOST}:${REDIS_PORT}"
echo ""
echo -e "${YELLOW}Tip: Workers scale automatically based on queue depth.${NC}"
echo -e "${YELLOW}     Monitor at: https://console.cloud.google.com/run?project=${GCP_PROJECT_ID}${NC}"
