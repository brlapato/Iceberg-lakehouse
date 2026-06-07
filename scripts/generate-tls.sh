#!/usr/bin/env bash
# Generate a self-signed TLS certificate for Trino (HTTPS) and create the
# K8s secrets that Trino reads at startup.
#
# Creates:
#   trino-tls              — keystore.p12 + cert.pem  (mounted at /etc/trino/tls/)
#   trino-internal-secret  — shared-secret             (coordinator-worker auth)
#
# Usage: NAMESPACE=lakehouse bash scripts/generate-tls.sh

set -euo pipefail

NAMESPACE="${NAMESPACE:-lakehouse}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log() { echo "[generate-tls] $*"; }

# ---------------------------------------------------------------------------
# Self-signed certificate (PKCS12 — no Java keytool required)
# ---------------------------------------------------------------------------
log "Generating self-signed certificate..."

openssl req -x509 -newkey rsa:4096 -days 3650 -nodes \
    -keyout "$WORKDIR/key.pem" \
    -out    "$WORKDIR/cert.pem" \
    -subj   "/CN=trino.lakehouse.svc.cluster.local/O=Lakehouse Dev" \
    -addext "subjectAltName=DNS:trino.lakehouse.svc.cluster.local,DNS:localhost,IP:127.0.0.1" \
    2>/dev/null

# Combined PEM keystore for Trino (airlift's ReloadableSslContextFactoryProvider
# reads PEM format: cert chain + unencrypted private key concatenated in one file)
cat "$WORKDIR/cert.pem" "$WORKDIR/key.pem" > "$WORKDIR/keystore.pem"

log "Certificate generated (10-year validity, SAN: trino.lakehouse.svc.cluster.local + localhost)"

# ---------------------------------------------------------------------------
# K8s secret: trino-tls
# ---------------------------------------------------------------------------
kubectl delete secret trino-tls --namespace "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
kubectl create secret generic trino-tls \
    --namespace "$NAMESPACE" \
    --from-file=keystore.pem="$WORKDIR/keystore.pem" \
    --from-file=cert.pem="$WORKDIR/cert.pem"
log "Secret 'trino-tls' created in namespace '$NAMESPACE'"

# ---------------------------------------------------------------------------
# K8s secret: trino-internal-secret  (coordinator ↔ worker shared secret)
# ---------------------------------------------------------------------------
SHARED_SECRET=$(openssl rand 512 | base64 | tr -d '\n')
kubectl delete secret trino-internal-secret --namespace "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
kubectl create secret generic trino-internal-secret \
    --namespace "$NAMESPACE" \
    --from-literal=shared-secret="$SHARED_SECRET"
log "Secret 'trino-internal-secret' created in namespace '$NAMESPACE'"

log ""
log "Done. Re-deploy Trino to pick up the new TLS certificate:"
log "  make trino"
