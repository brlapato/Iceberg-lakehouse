#!/usr/bin/env bash
# Bootstrap a single Polaris catalog and grant the trino principal access.
#
# Assumes the trino service principal and trino-role principal role already
# exist (created by init-polaris.sh on first deploy). Idempotent.
#
# Required env vars:
#   NAMESPACE           K8s namespace where Polaris is deployed
#   CATALOG_NAME        Name for both the Polaris catalog and the Trino catalog
#   S3_BUCKET           S3 bucket backing this catalog
#   S3_ENDPOINT         S3 endpoint URL
#   POLARIS_ROOT_ID     Root principal client ID
#   POLARIS_ROOT_SECRET Root principal client secret
#
# Usage (called by `make add-catalog`):
#   NAMESPACE=lakehouse CATALOG_NAME=research S3_BUCKET=research-data \
#   S3_ENDPOINT=http://... POLARIS_ROOT_ID=root POLARIS_ROOT_SECRET=secret \
#   bash scripts/init-catalog.sh

set -euo pipefail

NAMESPACE="${NAMESPACE:-lakehouse}"
CATALOG_NAME="${CATALOG_NAME:?CATALOG_NAME is required}"
S3_BUCKET="${S3_BUCKET:-${CATALOG_NAME}}"
S3_ENDPOINT="${S3_ENDPOINT:-http://seaweedfs-s3.${NAMESPACE}.svc.cluster.local:8333}"
ROOT_CLIENT_ID="${POLARIS_ROOT_ID:-root}"
ROOT_CLIENT_SECRET="${POLARIS_ROOT_SECRET:-polaris-dev-secret}"

PRINCIPAL_ROLE_NAME="trino-role"
CATALOG_ROLE_NAME="catalog-admin"
POLARIS_PORT=8181
LOCAL_PORT=8181
BASE_URL="http://localhost:${LOCAL_PORT}"

log() { echo "[init-catalog:${CATALOG_NAME}] $*"; }

# ---------------------------------------------------------------------------
# Port-forward
# ---------------------------------------------------------------------------
log "Waiting for Polaris deployment..."
kubectl rollout status deployment/polaris --namespace "${NAMESPACE}" --timeout=120s

log "Starting port-forward localhost:${LOCAL_PORT} -> polaris:${POLARIS_PORT}..."
kubectl port-forward --namespace "${NAMESPACE}" \
    svc/polaris "${LOCAL_PORT}:${POLARIS_PORT}" &
PF_PID=$!
trap 'log "Stopping port-forward"; kill "${PF_PID}" 2>/dev/null || true' EXIT

for i in $(seq 1 30); do
    if curl -so /dev/null -w "%{http_code}" "${BASE_URL}/api/catalog/v1/config" 2>/dev/null | grep -qE '^[2-4]'; then
        break
    fi
    sleep 2
done

# ---------------------------------------------------------------------------
# Root OAuth2 token
# ---------------------------------------------------------------------------
log "Obtaining root token..."
TOKEN_RESP=$(curl -sf -X POST "${BASE_URL}/api/catalog/v1/oauth/tokens" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" \
    -d "client_id=${ROOT_CLIENT_ID}" \
    -d "client_secret=${ROOT_CLIENT_SECRET}" \
    -d "scope=PRINCIPAL_ROLE:ALL")
ROOT_TOKEN=$(echo "${TOKEN_RESP}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))")
if [[ -z "${ROOT_TOKEN}" || "${ROOT_TOKEN}" == "null" ]]; then
    log "ERROR: Failed to obtain root token. Response: ${TOKEN_RESP}"
    exit 1
fi

auth() { echo "Authorization: Bearer ${ROOT_TOKEN}"; }

# ---------------------------------------------------------------------------
# Create catalog (idempotent)
# ---------------------------------------------------------------------------
log "Creating catalog '${CATALOG_NAME}' (location: s3://${S3_BUCKET}/${CATALOG_NAME}/)..."
RESP=$(curl -sf -X POST "${BASE_URL}/api/management/v1/catalogs" \
    -H "$(auth)" -H "Content-Type: application/json" \
    -d "{
  \"catalog\": {
    \"name\": \"${CATALOG_NAME}\",
    \"type\": \"INTERNAL\",
    \"properties\": {
      \"default-base-location\": \"s3://${S3_BUCKET}/${CATALOG_NAME}/\",
      \"s3.endpoint\": \"${S3_ENDPOINT}\",
      \"s3.path-style-access\": \"true\"
    },
    \"storageConfigInfo\": {
      \"storageType\": \"S3\",
      \"allowedLocations\": [\"s3://${S3_BUCKET}/${CATALOG_NAME}/\"],
      \"roleArn\": \"arn:aws:iam::000000000000:role/polaris-dev\",
      \"pathStyleAccess\": true,
      \"stsUnavailable\": true
    }
  }
}" 2>&1 || true)

if echo "${RESP}" | grep -q '"name"'; then
    log "Catalog '${CATALOG_NAME}' created."
elif echo "${RESP}" | grep -qi "already exists\|conflict\|409"; then
    log "Catalog '${CATALOG_NAME}' already exists — skipping."
else
    log "WARNING: Unexpected catalog response: ${RESP}"
fi

# ---------------------------------------------------------------------------
# Catalog role + grant + bind to principal role (all idempotent)
# ---------------------------------------------------------------------------
log "Granting access to principal role '${PRINCIPAL_ROLE_NAME}'..."

curl -sf -X POST \
    "${BASE_URL}/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles" \
    -H "$(auth)" -H "Content-Type: application/json" \
    -d "{\"catalogRole\": {\"name\": \"${CATALOG_ROLE_NAME}\"}}" \
    >/dev/null 2>&1 || true

curl -sf -X PUT \
    "${BASE_URL}/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles/${CATALOG_ROLE_NAME}/grants" \
    -H "$(auth)" -H "Content-Type: application/json" \
    -d "{\"grant\": {\"type\": \"catalog\", \"privilege\": \"CATALOG_MANAGE_CONTENT\"}}" \
    >/dev/null 2>&1 || true

curl -sf -X PUT \
    "${BASE_URL}/api/management/v1/principal-roles/${PRINCIPAL_ROLE_NAME}/catalog-roles/${CATALOG_NAME}" \
    -H "$(auth)" -H "Content-Type: application/json" \
    -d "{\"catalogRole\": {\"name\": \"${CATALOG_ROLE_NAME}\"}}" \
    >/dev/null 2>&1 || true

log "Done. Catalog '${CATALOG_NAME}' → principal role '${PRINCIPAL_ROLE_NAME}'."
