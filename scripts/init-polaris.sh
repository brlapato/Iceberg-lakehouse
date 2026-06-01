#!/usr/bin/env bash
# Bootstrap Apache Polaris after first deploy.
#
# What this script does:
#   1. Waits for the Polaris pod to be ready
#   2. Port-forwards Polaris :8181 to localhost temporarily
#   3. Obtains a root OAuth2 token
#   4. Creates the "warehouse" catalog (SeaweedFS S3-compatible backend)
#   5. Creates a "trino" service principal; captures its credentials
#   6. Creates a principal role, grants it full catalog access, binds the
#      trino principal to it
#   7. Writes credentials to K8s secret "polaris-trino-credentials"
#      (Trino reads this secret as env vars at startup)
#
# Usage:
#   NAMESPACE=lakehouse bash scripts/init-polaris.sh
#
# Requirements: kubectl, curl, jq

set -euo pipefail

NAMESPACE="${NAMESPACE:-lakehouse}"
POLARIS_SVC="polaris"
POLARIS_PORT=8181
LOCAL_PORT=8181
BASE_URL="http://localhost:${LOCAL_PORT}"

ROOT_CLIENT_ID="root"
ROOT_CLIENT_SECRET="polaris-dev-secret"

CATALOG_NAME="warehouse"
PRINCIPAL_NAME="trino"
PRINCIPAL_ROLE_NAME="trino-role"
CATALOG_ROLE_NAME="catalog-admin"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[init-polaris] $*"; }

wait_for_port() {
    local max=30
    for i in $(seq 1 $max); do
        if curl -sf "${BASE_URL}/healthcheck" >/dev/null 2>&1 || \
           curl -sf "${BASE_URL}/q/health" >/dev/null 2>&1 || \
           curl -so /dev/null -w "%{http_code}" "${BASE_URL}/api/catalog/v1/config" 2>/dev/null | grep -qE '^[2-4]'; then
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
# 2. Port-forward in background; clean up on exit
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
# 3. Obtain root OAuth2 token
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
# 4. Create the "warehouse" catalog
#    storageType S3 with a dummy roleArn (credential vending is disabled;
#    Trino manages its own S3 credentials directly).
# ---------------------------------------------------------------------------
log "Creating catalog '${CATALOG_NAME}'..."
CATALOG_RESP=$(curl -sf -X POST "${BASE_URL}/api/management/v1/catalogs" \
    -H "$(auth_header)" \
    -H "Content-Type: application/json" \
    -d "{
  \"catalog\": {
    \"name\": \"${CATALOG_NAME}\",
    \"type\": \"INTERNAL\",
    \"properties\": {
      \"default-base-location\": \"s3://warehouse/\",
      \"s3.endpoint\": \"http://seaweedfs-s3.lakehouse.svc.cluster.local:8333\",
      \"s3.path-style-access\": \"true\"
    },
    \"storageConfigInfo\": {
      \"storageType\": \"S3\",
      \"allowedLocations\": [\"s3://warehouse/\"],
      \"roleArn\": \"arn:aws:iam::000000000000:role/polaris-dev\",
      \"pathStyleAccess\": true,
      \"stsUnavailable\": true
    }
  }
}" 2>&1 || true)

if echo "${CATALOG_RESP}" | grep -q '"name"'; then
    log "Catalog '${CATALOG_NAME}' created."
elif echo "${CATALOG_RESP}" | grep -qi "already exists\|conflict\|409"; then
    log "Catalog '${CATALOG_NAME}' already exists — skipping."
else
    log "WARNING: Unexpected catalog response: ${CATALOG_RESP}"
fi

# ---------------------------------------------------------------------------
# 5. Create the "trino" service principal
# ---------------------------------------------------------------------------
log "Creating principal '${PRINCIPAL_NAME}'..."
PRINCIPAL_RESP=$(curl -sf -X POST "${BASE_URL}/api/management/v1/principals" \
    -H "$(auth_header)" \
    -H "Content-Type: application/json" \
    -d "{
  \"principal\": {
    \"name\": \"${PRINCIPAL_NAME}\",
    \"type\": \"SERVICE\"
  },
  \"credentialRotationRequired\": false
}" 2>&1 || true)

if echo "${PRINCIPAL_RESP}" | grep -qi "already exists\|conflict\|409"; then
    log "Principal '${PRINCIPAL_NAME}' already exists — rotating credentials to refresh secret..."
    PRINCIPAL_RESP=$(curl -sf -X POST \
        "${BASE_URL}/api/management/v1/principals/${PRINCIPAL_NAME}/rotate-credentials" \
        -H "$(auth_header)" \
        -H "Content-Type: application/json" \
        -d '{}' 2>&1 || true)
fi

CLIENT_ID=$(echo "${PRINCIPAL_RESP}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('credentials',{}).get('clientId',''))" 2>/dev/null || true)
CLIENT_SECRET=$(echo "${PRINCIPAL_RESP}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('credentials',{}).get('clientSecret',''))" 2>/dev/null || true)

if [[ -z "${CLIENT_ID}" || -z "${CLIENT_SECRET}" ]]; then
    log "ERROR: Could not extract principal credentials. Response: ${PRINCIPAL_RESP}"
    exit 1
fi
log "Principal '${PRINCIPAL_NAME}' ready (clientId=${CLIENT_ID})."

# ---------------------------------------------------------------------------
# 6a. Create a principal role
# ---------------------------------------------------------------------------
log "Creating principal role '${PRINCIPAL_ROLE_NAME}'..."
curl -sf -X POST "${BASE_URL}/api/management/v1/principal-roles" \
    -H "$(auth_header)" \
    -H "Content-Type: application/json" \
    -d "{\"principalRole\": {\"name\": \"${PRINCIPAL_ROLE_NAME}\"}}" \
    >/dev/null 2>&1 || log "Principal role '${PRINCIPAL_ROLE_NAME}' may already exist — continuing."

# 6b. Bind trino principal → principal role
log "Assigning principal '${PRINCIPAL_NAME}' to role '${PRINCIPAL_ROLE_NAME}'..."
curl -sf -X PUT \
    "${BASE_URL}/api/management/v1/principals/${PRINCIPAL_NAME}/principal-roles" \
    -H "$(auth_header)" \
    -H "Content-Type: application/json" \
    -d "{\"principalRole\": {\"name\": \"${PRINCIPAL_ROLE_NAME}\"}}" \
    >/dev/null 2>&1 || log "Assignment may already exist — continuing."

# 6c. Create a catalog role
log "Creating catalog role '${CATALOG_ROLE_NAME}' on '${CATALOG_NAME}'..."
curl -sf -X POST \
    "${BASE_URL}/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles" \
    -H "$(auth_header)" \
    -H "Content-Type: application/json" \
    -d "{\"catalogRole\": {\"name\": \"${CATALOG_ROLE_NAME}\"}}" \
    >/dev/null 2>&1 || log "Catalog role may already exist — continuing."

# 6d. Grant CATALOG_MANAGE_CONTENT to the catalog role
log "Granting CATALOG_MANAGE_CONTENT to catalog role '${CATALOG_ROLE_NAME}'..."
curl -sf -X PUT \
    "${BASE_URL}/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles/${CATALOG_ROLE_NAME}/grants" \
    -H "$(auth_header)" \
    -H "Content-Type: application/json" \
    -d "{\"grant\": {\"type\": \"catalog\", \"privilege\": \"CATALOG_MANAGE_CONTENT\"}}" \
    >/dev/null 2>&1 || log "Grant may already exist — continuing."

# 6e. Assign catalog role → principal role
log "Assigning catalog role to principal role..."
curl -sf -X PUT \
    "${BASE_URL}/api/management/v1/principal-roles/${PRINCIPAL_ROLE_NAME}/catalog-roles/${CATALOG_NAME}" \
    -H "$(auth_header)" \
    -H "Content-Type: application/json" \
    -d "{\"catalogRole\": {\"name\": \"${CATALOG_ROLE_NAME}\"}}" \
    >/dev/null 2>&1 || log "Catalog role assignment may already exist — continuing."

# ---------------------------------------------------------------------------
# 7. Write Trino OAuth2 credentials to K8s secret
#    Trino reads POLARIS_OAUTH_CREDENTIAL at startup (see trino/values.yaml).
# ---------------------------------------------------------------------------
log "Writing polaris-trino-credentials secret to namespace '${NAMESPACE}'..."
kubectl create secret generic polaris-trino-credentials \
    --namespace "${NAMESPACE}" \
    --from-literal="oauth-credential=${CLIENT_ID}:${CLIENT_SECRET}" \
    --dry-run=client -o yaml \
    | kubectl apply -f -

log "Done. Polaris is bootstrapped."
log "  Catalog      : ${CATALOG_NAME}"
log "  Principal    : ${PRINCIPAL_NAME}  (clientId=${CLIENT_ID})"
log "  K8s secret   : polaris-trino-credentials  (key: oauth-credential)"
log ""
log "Next step: make trino  (redeploys Trino with REST catalog config)"
