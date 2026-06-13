#!/usr/bin/env bash
# Add hostAliases to the Polaris deployment so Polaris can resolve
# virtual-hosted S3 bucket URLs (bucket.seaweedfs-s3.<ns>.svc.cluster.local)
# to the SeaweedFS S3 ClusterIP. The chart doesn't expose hostAliases, so we
# patch the Deployment directly. Idempotent — re-running replaces the list.
#
# Env vars:
#   NAMESPACE             K8s namespace
#   S3_SVC_NAME           SeaweedFS S3 service name (e.g. seaweedfs-s3)
#   CATALOGS              Space-separated catalog names
#   CATALOG_<n>_BUCKET    S3 bucket for each catalog
#
# Usage: NAMESPACE=lakehouse S3_SVC_NAME=seaweedfs-s3 CATALOGS='w r' ... bash scripts/patch-polaris-hosts.sh

set -euo pipefail

NAMESPACE="${NAMESPACE:-lakehouse}"
S3_SVC="${S3_SVC_NAME:-seaweedfs-s3}"
CATALOGS="${CATALOGS:?CATALOGS is required}"

log() { echo "[patch-polaris] $*"; }

S3_IP=$(kubectl get svc "${S3_SVC}" --namespace "${NAMESPACE}" \
    -o jsonpath='{.spec.clusterIP}')
if [[ -z "${S3_IP}" ]]; then
    log "ERROR: could not determine ${S3_SVC} ClusterIP in namespace ${NAMESPACE}"
    exit 1
fi
log "SeaweedFS S3 ClusterIP: ${S3_IP}"

# Build the JSON hostnames array — one entry per unique bucket
declare -A seen
HOSTNAMES_JSON=""
for catalog in ${CATALOGS}; do
    bucket_var="CATALOG_${catalog}_BUCKET"
    bucket="${!bucket_var:-${catalog}}"
    hostname="${bucket}.${S3_SVC}.${NAMESPACE}.svc.cluster.local"
    if [[ -z "${seen[${bucket}]+x}" ]]; then
        [[ -n "${HOSTNAMES_JSON}" ]] && HOSTNAMES_JSON+=","
        HOSTNAMES_JSON+="\"${hostname}\""
        seen["${bucket}"]=1
        log "Adding hostname: ${hostname}"
    fi
done

log "Patching polaris deployment with hostAliases..."
kubectl patch deployment polaris --namespace "${NAMESPACE}" --type=json \
    -p "[{
  \"op\": \"add\",
  \"path\": \"/spec/template/spec/hostAliases\",
  \"value\": [{\"ip\": \"${S3_IP}\", \"hostnames\": [${HOSTNAMES_JSON}]}]
}]"

log "Waiting for Polaris rollout after hostAliases patch..."
kubectl rollout status deployment/polaris --namespace "${NAMESPACE}" --timeout=120s
log "Done."
