#!/usr/bin/env bash
# ============================================================
# n8n on GCP Cloud Run — Automated Deployment
# ============================================================
# Usage:  ./deploy.sh            # full deploy (all 5 phases)
#         ./deploy.sh --redeploy  # update Cloud Run only (phase 5)
# Config: .env (must exist in the same directory)
# ============================================================
set -euo pipefail

# ── Parse flags ──────────────────────────────────────────────
REDEPLOY_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --redeploy) REDEPLOY_ONLY=true ;;
    --help|-h)
      echo "Usage: ./deploy.sh [--redeploy]"
      echo "  --redeploy  Skip infrastructure (phases 1-4), only update Cloud Run"
      exit 0 ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

phase()  { echo -e "\n${CYAN}━━━ Phase $1: $2 ━━━${NC}\n"; }
info()   { echo -e "${GREEN}✔ $1${NC}"; }
warn()   { echo -e "${YELLOW}⚠ $1${NC}"; }
fail()   { echo -e "${RED}✖ $1${NC}"; exit 1; }

# ── Load .env ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  fail ".env file not found at ${ENV_FILE}. Copy .env.example and fill in your values."
fi

set -a
# shellcheck source=.env
source "$ENV_FILE"
set +a

# Validate required vars
for var in GCP_PROJECT_ID GCP_REGION DB_INSTANCE_NAME DB_VERSION DB_TIER \
           DB_NAME DB_USER DB_PASSWORD SECRET_DB_PASSWORD SECRET_ENCRYPTION_KEY \
           CLOUD_RUN_SERVICE CLOUD_RUN_MEMORY CLOUD_RUN_PORT SERVICE_ACCOUNT_NAME; do
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
MIN_INSTANCES="${CLOUD_RUN_MIN_INSTANCES:-0}"
MAX_INSTANCES="${CLOUD_RUN_MAX_INSTANCES:-3}"
N8N_IMAGE="n8nio/n8n:${N8N_VERSION:-latest}"

echo -e "${CYAN}Project:    ${NC}${GCP_PROJECT_ID}"
echo -e "${CYAN}Region:     ${NC}${GCP_REGION}"
echo -e "${CYAN}Service:    ${NC}${CLOUD_RUN_SERVICE}"
echo -e "${CYAN}DB Instance:${NC}${DB_INSTANCE_NAME}"
echo -e "${CYAN}SA Email:   ${NC}${SA_EMAIL}"
echo -e "${CYAN}n8n Image:  ${NC}${N8N_IMAGE}"

if $REDEPLOY_ONLY; then
  warn "--redeploy: skipping phases 1-4, jumping to Cloud Run deploy"
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
)

gcloud services enable "${APIS[@]}" --project="$GCP_PROJECT_ID"
info "All required APIs enabled."

# ═════════════════════════════════════════════════════════════
# PHASE 2: Cloud SQL (Postgres)
# ═════════════════════════════════════════════════════════════
phase 2 "Cloud SQL — Postgres Instance, Database & User"

# 2a. Create instance (skip if exists)
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

# 2b. Create database (skip if exists)
if gcloud sql databases describe "$DB_NAME" --instance="$DB_INSTANCE_NAME" --project="$GCP_PROJECT_ID" &>/dev/null; then
  info "Database '${DB_NAME}' already exists — skipping."
else
  gcloud sql databases create "$DB_NAME" \
    --instance="$DB_INSTANCE_NAME" \
    --project="$GCP_PROJECT_ID"
  info "Database '${DB_NAME}' created."
fi

# 2c. Create user (skip if exists)
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

# 3a. DB password secret
if gcloud secrets describe "$SECRET_DB_PASSWORD" --project="$GCP_PROJECT_ID" &>/dev/null; then
  info "Secret '${SECRET_DB_PASSWORD}' already exists — skipping."
else
  printf '%s' "$DB_PASSWORD" | gcloud secrets create "$SECRET_DB_PASSWORD" \
    --data-file=- \
    --replication-policy=automatic \
    --project="$GCP_PROJECT_ID"
  info "Secret '${SECRET_DB_PASSWORD}' created."
fi

# 3b. n8n encryption key (generate once, store forever)
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
# PHASE 4: Service Account & IAM
# ═════════════════════════════════════════════════════════════
phase 4 "Service Account & IAM Bindings"

# 4a. Create service account
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$GCP_PROJECT_ID" &>/dev/null; then
  info "Service account '${SERVICE_ACCOUNT_NAME}' already exists — skipping."
else
  gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
    --display-name="Service Account for n8n Cloud Run" \
    --project="$GCP_PROJECT_ID"
  info "Service account '${SERVICE_ACCOUNT_NAME}' created."
fi

# 4b. Grant Cloud SQL Client role
gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/cloudsql.client" \
  --condition=None \
  --quiet
info "Granted roles/cloudsql.client to ${SERVICE_ACCOUNT_NAME}."

# 4c. Grant Secret Accessor on DB password secret
gcloud secrets add-iam-policy-binding "$SECRET_DB_PASSWORD" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --project="$GCP_PROJECT_ID" \
  --quiet
info "Granted secretAccessor on '${SECRET_DB_PASSWORD}'."

# 4d. Grant Secret Accessor on encryption key secret
gcloud secrets add-iam-policy-binding "$SECRET_ENCRYPTION_KEY" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --project="$GCP_PROJECT_ID" \
  --quiet
info "Granted secretAccessor on '${SECRET_ENCRYPTION_KEY}'."

fi  # end of REDEPLOY_ONLY skip

# ═════════════════════════════════════════════════════════════
# PHASE 5: Deploy to Cloud Run
# ═════════════════════════════════════════════════════════════
phase 5 "Deploy n8n to Cloud Run"

# Auto-detect WEBHOOK_URL from existing deployment (if any)
SERVICE_URL=$(gcloud run services describe "$CLOUD_RUN_SERVICE" \
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
  --set-env-vars="\
DB_TYPE=postgresdb,\
DB_POSTGRESDB_HOST=/cloudsql/${CONNECTION_NAME},\
DB_POSTGRESDB_DATABASE=${DB_NAME},\
DB_POSTGRESDB_USER=${DB_USER},\
DB_POSTGRESDB_PORT=5432,\
EXECUTIONS_DATA_SAVE_ON_ERROR=all,\
EXECUTIONS_DATA_SAVE_ON_SUCCESS=all,\
N8N_DIAGNOSTICS_ENABLED=false,\
N8N_ENDPOINT_HEALTH=health,\
N8N_PAYLOAD_SIZE_MAX=${N8N_PAYLOAD_SIZE_MAX:-256},\
N8N_CONCURRENCY_PRODUCTION_LIMIT=${N8N_CONCURRENCY_PRODUCTION_LIMIT:-20},\
N8N_PROCESS_TIMEOUT=${N8N_PROCESS_TIMEOUT:-7200000},\
N8N_LOG_LEVEL=${N8N_LOG_LEVEL:-info},\
WEBHOOK_URL=${SERVICE_URL:-},\N8N_PROXY_HOPS=${N8N_PROXY_HOPS:-1},GENERIC_TIMEZONE=${GENERIC_TIMEZONE:-Europe/Amsterdam}" \
  --set-secrets="\
DB_POSTGRESDB_PASSWORD=${SECRET_DB_PASSWORD}:latest,\
N8N_ENCRYPTION_KEY=${SECRET_ENCRYPTION_KEY}:latest"

info "Cloud Run service '${CLOUD_RUN_SERVICE}' deployed."

# ── Print result ─────────────────────────────────────────────
# Use the new-format URL (project-number + region based)
SERVICE_URL="https://${CLOUD_RUN_SERVICE}-${GCP_PROJECT_NUMBER}.${GCP_REGION}.run.app"
# Fallback: fetch from gcloud if project number isn't available
GCP_PROJECT_NUMBER=$(gcloud projects describe "$GCP_PROJECT_ID" --format="value(projectNumber)" 2>/dev/null || true)
if [[ -n "$GCP_PROJECT_NUMBER" ]]; then
  SERVICE_URL="https://${CLOUD_RUN_SERVICE}-${GCP_PROJECT_NUMBER}.${GCP_REGION}.run.app"
else
  SERVICE_URL=$(gcloud run services describe "$CLOUD_RUN_SERVICE" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT_ID" \
    --format="value(status.url)")
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  n8n is live at: ${SERVICE_URL}${NC}"
echo -e "${GREEN}  Health check:   ${SERVICE_URL}/health${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}Tip: Protect the UI! Consider adding n8n basic auth or GCP IAP.${NC}"
