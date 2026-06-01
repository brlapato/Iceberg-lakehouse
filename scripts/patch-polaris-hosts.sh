#!/usr/bin/env bash
# Add hostAliases to the Polaris deployment so Polaris can resolve
# virtual-hosted S3 URLs (e.g. warehouse.seaweedfs-s3.lakehouse.svc.cluster.local)
# to the SeaweedFS S3 ClusterIP. The chart doesn't expose hostAliases, so we
# patch the Deployment directly. This patch is pod-scoped only.
#
# Usage: NAMESPACE=lakehouse bash scripts/patch-polaris-hosts.sh

set -euo pipefail

NAMESPACE="${NAMESPACE:-lakehouse}"

log() { echo "[patch-polaris] $*"; }

S3_IP=$(kubectl get svc seaweedfs-s3 --namespace "$NAMESPACE" \
    -o jsonpath='{.spec.clusterIP}')

if [[ -z "$S3_IP" ]]; then
    log "ERROR: could not determine seaweedfs-s3 ClusterIP in namespace $NAMESPACE"
    exit 1
fi

log "SeaweedFS S3 ClusterIP: $S3_IP"
log "Patching polaris deployment with hostAliases..."

kubectl patch deployment polaris --namespace "$NAMESPACE" --type=json \
    -p "[
  {
    \"op\": \"add\",
    \"path\": \"/spec/template/spec/hostAliases\",
    \"value\": [
      {
        \"ip\": \"$S3_IP\",
        \"hostnames\": [
          \"warehouse.seaweedfs-s3.${NAMESPACE}.svc.cluster.local\"
        ]
      }
    ]
  }
]"

log "Waiting for Polaris rollout after hostAliases patch..."
kubectl rollout status deployment/polaris --namespace "$NAMESPACE" --timeout=120s

log "Done. warehouse.seaweedfs-s3.${NAMESPACE}.svc.cluster.local -> $S3_IP"
