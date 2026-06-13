#!/usr/bin/env bash
# Bootstrap Apache Polaris after first deploy.
#
# What this script does:
#   1. Waits for the Polaris pod to be ready
#   2. Port-forwards Polaris :8181 to localhost temporarily
#   3. Obtains a root OAuth2 token
#   4. Creates the "trino" service principal and "trino-role" principal role
#   5. Writes the polaris-trino-credentials K8s secret (read by Trino at startup)
#   6. For each catalog in CATALOGS: creates the Polaris catalog, catalog role,
#      grants CATALOG_MANAGE_CONTENT, and binds the catalog role to trino-role
#
# Env vars:
#   NAMESPACE           K8s namespace
#   POLARIS_ROOT_ID     Root principal client ID   (default: root)
#   POLARIS_ROOT_SECRET Root principal client secret
#   CATALOGS            Space-separated catalog names
#   CATALOG_<n>_BUCKET  S3 bucket for each catalog (defaults to catalog name)
#   S3_ENDPOINT         S3 endpoint URL
#
# Usage:
#   NAMESPACE=lakehouse CATALOGS='warehouse research' \
#   CATALOG_warehouse_BUCKET=warehouse CATALOG_research_BUCKET=research-data \
#   bash scripts/init-polaris.sh
#
# Requirements: kubectl, curl, python3

set -euo pipefail

NAMESPACE="${NAMESPACE:-lakehouse}"
POLARIS_SVC="polaris"
POLARIS_PORT=8181
LOCAL_PORT=8181
BASE_URL="http://localhost:${LOCAL_PORT}"

ROOT_CLIENT_ID="${POLARIS_ROOT_ID:-root}"
ROOT_CLIENT_SECRET="${POLARIS_ROOT_SECRET:-polaris-dev-secret}"
CATALOGS="${CATALOGS:?CATALOGS is required}"
S3_ENDPOINT="${S3_ENDPOINT:-http://seaweedfs-s3.${NAMESPACE}.svc.cluster.local:8333}"

PRINCIPAL_NAME="trino"
PRINCIPAL_ROLE_NAME="trino-role"
CATALOG_ROLE_NAME="catalog-admin"

log() { echo "[init-polaris] $*"; }

wait_for_port() {
    local max=30
    for i in $(seq 1 $max); do
        if curl -so /dev/null -w "%{http_code}" "${BASE_URL}/api/catalog/v1/config" 2>/dev/null | grep -qE '^[2-4]'; then
            return 0
        fi
        sleep 2
    done
    log "ERROR: Polaris did not become reachable on localhost:${LOCAL_PORT} after $((max*2))s"
    return 1
}

# ---------------------------------------------------------------------------
# 1. Wait for Polaris deployment
# ---------------------------------------------------------------------------
log "Waiting for Polaris deployment to roll out..."
kubectl rollout status deployment/"${POLARIS_SVC}" \
    --namespace "${NAMESPACE}" --timeout=120s

# ---------------------------------------------------------------------------
# 2. Port-forward; clean up on exit
# ---------------------------------------------------------------------------
log "Starting port-forward localhost:${LOCAL_PORT} -> ${POLARIS_SVC}:${POLARIS_PORT}..."
kubectl port-forward \
    --namespace "${NAMESPACE}" \
    "svc/${POLARIS_SVC}" "${LOCAL_PORT}:${POLARIS_PORT}" &
PF_PID=$!
trap 'log "Stopping port-forward (pid ${PF_PID})"; kill "${PF_PID}" 2>/dev/null || true' EXIT

log "Waiting for Polaris to accept connections..."
wait_for_port

# ---------------------------------------------------------------------------
# 3. Root OAuth2 token
# ---------------------------------------------------------------------------
log "Obtaining root token..."
TOKEN_RESPONSE=$(curl -sf -X POST "${BASE_URL}/api/catalog/v1/oauth/tokens" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" \
    -d "client_id=${ROOT_CLIENT_ID}" \
    -d "client_secret=${ROOT_CLIENT_SECRET}" \
    -d "scope=PRINCIPAL_ROLE:ALL")
ROOT_TOKEN=$(echo "${TOKEN_RESPONSE}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))")
if [[ -z "${ROOT_TOKEN}" || "${ROOT_TOKEN}" == "null" ]]; then
    log "ERROR: Failed to obtain root token. Response: ${TOKEN_RESPONSE}"
    exit 1
fi
log "Root token obtained."

auth_header() { echo "Authorization: Bearer ${ROOT_TOKEN}"; }

# ---------------------------------------------------------------------------
# 4. Create the "trino" service principal (rotate credentials if it exists)
# ---------------------------------------------------------------------------
log "Creating principal '${PRINCIPAL_NAME}'..."
PRINCIPAL_RESP=$(curl -sf -X POST "${BASE_URL}/api/management/v1/principals" \
    -H "$(auth_header)" -H "Content-Type: application/json" \
    -d "{
  \"principal\": {\"name\": \"${PRINCIPAL_NAME}\", \"type\": \"SERVICE\"},
  \"credentialRotationRequired\": false
}" 2>&1 || true)

if echo "${PRINCIPAL_RESP}" | grep -qi "already exists\|conflict\|409"; then
    log "Principal '${PRINCIPAL_NAME}' already exists — rotating credentials..."
    PRINCIPAL_RESP=$(curl -sf -X POST \
        "${BASE_URL}/api/management/v1/principals/${PRINCIPAL_NAME}/rotate-credentials" \
        -H "$(auth_header)" -H "Content-Type: application/json" \
        -d '{}' 2>&1 || true)
fi

CLIENT_ID=$(echo "${PRINCIPAL_RESP}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('credentials',{}).get('clientId',''))" 2>/dev/null || true)
CLIENT_SECRET=$(echo "${PRINCIPAL_RESP}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('credentials',{}).get('clientSecret',''))" 2>/dev/null || true)

if [[ -z "${CLIENT_ID}" || -z "${CLIENT_SECRET}" ]]; then
    log "ERROR: Could not extract principal credentials. Response: ${PRINCIPAL_RESP}"
    exit 1
fi
log "Principal '${PRINCIPAL_NAME}' ready (clientId=${CLIENT_ID})."

# ---------------------------------------------------------------------------
# 4b. Create principal role and bind trino principal to it
# ---------------------------------------------------------------------------
log "Creating principal role '${PRINCIPAL_ROLE_NAME}'..."
curl -sf -X POST "${BASE_URL}/api/management/v1/principal-roles" \
    -H "$(auth_header)" -H "Content-Type: application/json" \
    -d "{\"principalRole\": {\"name\": \"${PRINCIPAL_ROLE_NAME}\"}}" \
    >/dev/null 2>&1 || log "Principal role may already exist — continuing."

curl -sf -X PUT \
    "${BASE_URL}/api/management/v1/principals/${PRINCIPAL_NAME}/principal-roles" \
    -H "$(auth_header)" -H "Content-Type: application/json" \
    -d "{\"principalRole\": {\"name\": \"${PRINCIPAL_ROLE_NAME}\"}}" \
    >/dev/null 2>&1 || log "Principal role assignment may already exist — continuing."

# ---------------------------------------------------------------------------
# 5. Write Trino OAuth2 credentials to K8s secret
# ---------------------------------------------------------------------------
log "Writing polaris-trino-credentials secret..."
kubectl create secret generic polaris-trino-credentials \
    --namespace "${NAMESPACE}" \
    --from-literal="oauth-credential=${CLIENT_ID}:${CLIENT_SECRET}" \
    --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------
# 6. Create each catalog, grant trino-role access
# ---------------------------------------------------------------------------
for catalog in ${CATALOGS}; do
    bucket_var="CATALOG_${catalog}_BUCKET"
    bucket="${!bucket_var:-${catalog}}"

    log "--- Catalog: ${catalog} (location: s3://${bucket}/${catalog}/) ---"

    CATALOG_RESP=$(curl -sf -X POST "${BASE_URL}/api/management/v1/catalogs" \
        -H "$(auth_header)" -H "Content-Type: application/json" \
        -d "{
  \"catalog\": {
    \"name\": \"${catalog}\",
    \"type\": \"INTERNAL\",
    \"properties\": {
      \"default-base-location\": \"s3://${bucket}/${catalog}/\",
      \"s3.endpoint\": \"${S3_ENDPOINT}\",
      \"s3.path-style-access\": \"true\"
    },
    \"storageConfigInfo\": {
      \"storageType\": \"S3\",
      \"allowedLocations\": [\"s3://${bucket}/${catalog}/\"],
      \"roleArn\": \"arn:aws:iam::000000000000:role/polaris-dev\",
      \"pathStyleAccess\": true,
      \"stsUnavailable\": true
    }
  }
}" 2>&1 || true)

    if echo "${CATALOG_RESP}" | grep -q '"name"'; then
        log "Catalog '${catalog}' created."
    elif echo "${CATALOG_RESP}" | grep -qi "already exists\|conflict\|409"; then
        log "Catalog '${catalog}' already exists — skipping."
    else
        log "WARNING: Unexpected catalog response: ${CATALOG_RESP}"
    fi

    curl -sf -X POST \
        "${BASE_URL}/api/management/v1/catalogs/${catalog}/catalog-roles" \
        -H "$(auth_header)" -H "Content-Type: application/json" \
        -d "{\"catalogRole\": {\"name\": \"${CATALOG_ROLE_NAME}\"}}" \
        >/dev/null 2>&1 || true

    curl -sf -X PUT \
        "${BASE_URL}/api/management/v1/catalogs/${catalog}/catalog-roles/${CATALOG_ROLE_NAME}/grants" \
        -H "$(auth_header)" -H "Content-Type: application/json" \
        -d "{\"grant\": {\"type\": \"catalog\", \"privilege\": \"CATALOG_MANAGE_CONTENT\"}}" \
        >/dev/null 2>&1 || true

    curl -sf -X PUT \
        "${BASE_URL}/api/management/v1/principal-roles/${PRINCIPAL_ROLE_NAME}/catalog-roles/${catalog}" \
        -H "$(auth_header)" -H "Content-Type: application/json" \
        -d "{\"catalogRole\": {\"name\": \"${CATALOG_ROLE_NAME}\"}}" \
        >/dev/null 2>&1 || true

    log "Catalog '${catalog}' → principal role '${PRINCIPAL_ROLE_NAME}'."
done

log ""
log "Done. Polaris is bootstrapped."
log "  Catalogs     : ${CATALOGS}"
log "  Principal    : ${PRINCIPAL_NAME}  (clientId=${CLIENT_ID})"
log "  K8s secret   : polaris-trino-credentials"
log ""
log "Next step: make trino"
