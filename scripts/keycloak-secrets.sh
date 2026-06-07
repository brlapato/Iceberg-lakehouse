#!/usr/bin/env bash
# Creates K8s secrets for Keycloak client credentials.
# Run this after creating the Trino and OpenMetadata clients in Keycloak.
#
# Reads:  config/lakehouse-config.yaml  (for client IDs)
# Creates:
#   keycloak-trino        — key: client-secret
#   keycloak-openmetadata — key: client-secret
#
# Usage: bash scripts/keycloak-secrets.sh

set -euo pipefail

NAMESPACE="${NAMESPACE:-lakehouse}"
CONFIG="config/lakehouse-config.yaml"

log() { echo "[keycloak-secrets] $*"; }
die() { echo "[keycloak-secrets] ERROR: $*" >&2; exit 1; }

[[ -f "$CONFIG" ]] || die "config/lakehouse-config.yaml not found."

KEYCLOAK_URL=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG'))['data']['KEYCLOAK_URL'])")
KEYCLOAK_REALM=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG'))['data']['KEYCLOAK_REALM'])")
TRINO_CLIENT_ID=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG'))['data']['KEYCLOAK_TRINO_CLIENT_ID'])")
OM_CLIENT_ID=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG'))['data']['KEYCLOAK_OM_CLIENT_ID'])")

log "Keycloak: $KEYCLOAK_URL  realm: $KEYCLOAK_REALM"
log ""

# ---------------------------------------------------------------------------
# Trino client secret
# ---------------------------------------------------------------------------
log "Keycloak client '$TRINO_CLIENT_ID' (for Trino OAuth2)"
read -rsp "  Enter client secret: " TRINO_SECRET
echo
[[ -n "$TRINO_SECRET" ]] || die "Trino client secret cannot be empty"

kubectl delete secret keycloak-trino --namespace "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
kubectl create secret generic keycloak-trino \
    --namespace "$NAMESPACE" \
    --from-literal=client-secret="$TRINO_SECRET"
log "Secret 'keycloak-trino' created."

# ---------------------------------------------------------------------------
# OpenMetadata client secret
# ---------------------------------------------------------------------------
log ""
log "Keycloak client '$OM_CLIENT_ID' (for OpenMetadata SSO)"
read -rsp "  Enter client secret: " OM_SECRET
echo
[[ -n "$OM_SECRET" ]] || die "OpenMetadata client secret cannot be empty"

kubectl delete secret keycloak-openmetadata --namespace "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
kubectl create secret generic keycloak-openmetadata \
    --namespace "$NAMESPACE" \
    --from-literal=client-secret="$OM_SECRET"
log "Secret 'keycloak-openmetadata' created."

log ""
log "Done. Next steps:"
log "  make keycloak-config   # propagate config/lakehouse-config.yaml into values files"
log "  make trino             # redeploy Trino with OAuth2 config"
log "  make openmetadata      # redeploy OpenMetadata with OIDC SSO"
