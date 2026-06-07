#!/usr/bin/env bash
# init-storage.sh — creates the 'warehouse' bucket in SeaweedFS after deploy.
#
# Prerequisites:
#   - aws CLI installed  (or swap for 'mc' / 'mc mb')
#   - kubectl configured for the target cluster
#
# Usage:
#   NAMESPACE=lakehouse bash scripts/init-storage.sh

set -euo pipefail

NAMESPACE=${NAMESPACE:-lakehouse}
S3_SVC="${S3_SVC_NAME:-seaweedfs-s3}"
S3_PORT=8333
LOCAL_PORT=18333
ACCESS_KEY="${S3_ACCESS_KEY:-lakehouse-access-key}"
SECRET_KEY="${S3_SECRET_KEY:-lakehouse-secret-key}"
BUCKET="${S3_BUCKET:-warehouse}"

echo "==> Port-forwarding SeaweedFS S3 (${S3_SVC} in ${NAMESPACE})..."
kubectl port-forward \
  --namespace "${NAMESPACE}" \
  "svc/${S3_SVC}" \
  "${LOCAL_PORT}:${S3_PORT}" &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
sleep 4

ENDPOINT="http://localhost:${LOCAL_PORT}"

echo "==> Creating bucket: s3://${BUCKET}"
AWS_ACCESS_KEY_ID="${ACCESS_KEY}" \
AWS_SECRET_ACCESS_KEY="${SECRET_KEY}" \
aws s3 mb "s3://${BUCKET}" \
  --endpoint-url "${ENDPOINT}" \
  --region us-east-1 \
  --no-verify-ssl

echo "==> Listing buckets to verify:"
AWS_ACCESS_KEY_ID="${ACCESS_KEY}" \
AWS_SECRET_ACCESS_KEY="${SECRET_KEY}" \
aws s3 ls \
  --endpoint-url "${ENDPOINT}" \
  --region us-east-1 \
  --no-verify-ssl

echo "==> Done. Bucket '${BUCKET}' is ready."
