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
RELEASE=${RELEASE:-seaweedfs}
S3_PORT=8333
LOCAL_PORT=18333
ACCESS_KEY="lakehouse-access-key"
SECRET_KEY="lakehouse-secret-key"
BUCKET="warehouse"

echo "==> Port-forwarding SeaweedFS S3 (${RELEASE} in ${NAMESPACE})..."
kubectl port-forward \
  --namespace "${NAMESPACE}" \
  "svc/${RELEASE}-filer" \
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
