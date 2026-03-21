#!/usr/bin/env bash
# ============================================================
# n8n on GCP — Teardown (delete all resources)
# ============================================================
# Usage:  ./teardown.sh
# Config: .env (same file used by deploy.sh)
#
# ⚠ THIS IS DESTRUCTIVE — all data will be permanently lost.
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

info() { echo -e "${GREEN}✔ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
fail() { echo -e "${RED}✖ $1${NC}"; exit 1; }

# ── Load .env ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  fail ".env file not found at ${ENV_FILE}."
fi

set -a
source "$ENV_FILE"
set +a

SA_EMAIL="${SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

# ── Confirmation ─────────────────────────────────────────────
echo ""
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}  ⚠  THIS WILL PERMANENTLY DELETE:${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Cloud Run service:  ${CYAN}${CLOUD_RUN_SERVICE}${NC}"
echo -e "  Cloud SQL instance: ${CYAN}${DB_INSTANCE_NAME}${NC} (including database & users)"
echo -e "  Secret:             ${CYAN}${SECRET_DB_PASSWORD}${NC}"
echo -e "  Secret:             ${CYAN}${SECRET_ENCRYPTION_KEY}${NC}"
echo -e "  Service account:    ${CYAN}${SA_EMAIL}${NC}"
echo -e "  Project:            ${CYAN}${GCP_PROJECT_ID}${NC}"
echo -e "  Region:             ${CYAN}${GCP_REGION}${NC}"
echo ""
echo -e "${RED}  All workflows, credentials, and execution data will be LOST.${NC}"
echo ""
read -rp "Type 'DELETE' to confirm: " CONFIRM

if [[ "$CONFIRM" != "DELETE" ]]; then
  echo "Aborted."
  exit 0
fi

echo ""

# ── 1. Delete Cloud Run service ──────────────────────────────
echo -e "${CYAN}Deleting Cloud Run service…${NC}"
if gcloud run services describe "$CLOUD_RUN_SERVICE" \
    --region="$GCP_REGION" --project="$GCP_PROJECT_ID" &>/dev/null; then
  gcloud run services delete "$CLOUD_RUN_SERVICE" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT_ID" \
    --quiet
  info "Cloud Run service '${CLOUD_RUN_SERVICE}' deleted."
else
  warn "Cloud Run service '${CLOUD_RUN_SERVICE}' not found — skipping."
fi

# ── 2. Delete Cloud SQL instance ─────────────────────────────
echo -e "${CYAN}Deleting Cloud SQL instance (this takes a few minutes)…${NC}"
if gcloud sql instances describe "$DB_INSTANCE_NAME" --project="$GCP_PROJECT_ID" &>/dev/null; then
  gcloud sql instances delete "$DB_INSTANCE_NAME" \
    --project="$GCP_PROJECT_ID" \
    --quiet
  info "Cloud SQL instance '${DB_INSTANCE_NAME}' deleted."
else
  warn "Cloud SQL instance '${DB_INSTANCE_NAME}' not found — skipping."
fi

# ── 3. Delete secrets ────────────────────────────────────────
echo -e "${CYAN}Deleting secrets…${NC}"
for secret in "$SECRET_DB_PASSWORD" "$SECRET_ENCRYPTION_KEY"; do
  if gcloud secrets describe "$secret" --project="$GCP_PROJECT_ID" &>/dev/null; then
    gcloud secrets delete "$secret" \
      --project="$GCP_PROJECT_ID" \
      --quiet
    info "Secret '${secret}' deleted."
  else
    warn "Secret '${secret}' not found — skipping."
  fi
done

# ── 4. Delete service account ────────────────────────────────
echo -e "${CYAN}Deleting service account…${NC}"
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$GCP_PROJECT_ID" &>/dev/null; then
  gcloud iam service-accounts delete "$SA_EMAIL" \
    --project="$GCP_PROJECT_ID" \
    --quiet
  info "Service account '${SA_EMAIL}' deleted."
else
  warn "Service account '${SA_EMAIL}' not found — skipping."
fi

# ── Done ─────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  All resources deleted. Project ${GCP_PROJECT_ID} is clean.${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
