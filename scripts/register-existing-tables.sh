#!/usr/bin/env bash
# Register pre-existing Iceberg tables from SeaweedFS into Polaris.
#
# When switching from Nessie to Polaris, catalog metadata is lost but the
# Iceberg data files (Parquet + metadata JSON) remain in SeaweedFS.  This
# script re-registers them via Trino's CALL system.register_table procedure
# so existing data is immediately queryable without a full reload.
#
# Each register_table call is idempotent-ish: it will error if the table
# already exists in the catalog, but the script treats those as warnings and
# continues.
#
# Usage:
#   NAMESPACE=lakehouse bash scripts/register-existing-tables.sh
#
# Requirements: kubectl (with access to the lakehouse namespace)

set -euo pipefail

NAMESPACE="${NAMESPACE:-lakehouse}"
CATALOG="lakehouse"

log() { echo "[register-tables] $*"; }

# Run a single SQL statement via Trino CLI inside the coordinator pod.
# Returns 0 on success, non-zero on failure (caller decides whether to abort).
trino_exec() {
    local sql="$1"
    kubectl exec -n "${NAMESPACE}" deploy/trino-coordinator -- \
        trino \
            --server http://localhost:8080 \
            --catalog "${CATALOG}" \
            --execute "${sql}" \
            --output-format TSV \
            2>&1
}

log "Waiting for Trino coordinator to be ready..."
kubectl rollout status deployment/trino-coordinator \
    --namespace "${NAMESPACE}" --timeout=120s

log "Creating schemas (idempotent)..."

trino_exec "CREATE SCHEMA IF NOT EXISTS ${CATALOG}.financial WITH (location = 's3://warehouse/financial/')" \
    && log "  financial schema ready" \
    || log "  WARNING: financial schema creation returned an error (may already exist)"

trino_exec "CREATE SCHEMA IF NOT EXISTS ${CATALOG}.trading WITH (location = 's3://warehouse/trading/')" \
    && log "  trading schema ready" \
    || log "  WARNING: trading schema creation returned an error (may already exist)"

log "Registering tables..."

register_table() {
    local schema="$1"
    local table="$2"
    local location="$3"
    local sql="CALL ${CATALOG}.system.register_table(schema_name => '${schema}', table_name => '${table}', table_location => '${location}')"
    if trino_exec "${sql}" >/dev/null 2>&1; then
        log "  registered ${schema}.${table}"
    else
        log "  SKIP ${schema}.${table} (not found in SeaweedFS or already registered)"
    fi
}

# Tables written by notebooks/financial_timeseries.ipynb
register_table financial stock_prices    "s3://warehouse/financial/stock_prices"

# Tables written by notebooks/openmetadata_lineage.ipynb
register_table trading raw_trades        "s3://warehouse/trading/raw_trades"
register_table trading raw_instruments   "s3://warehouse/trading/raw_instruments"
register_table trading enriched_trades   "s3://warehouse/trading/enriched_trades"
register_table trading daily_pnl         "s3://warehouse/trading/daily_pnl"
register_table trading risk_report       "s3://warehouse/trading/risk_report"

log ""
log "Done. Run 'kubectl exec -n ${NAMESPACE} deploy/trino-coordinator -- trino --execute \"SHOW SCHEMAS IN ${CATALOG}\"' to verify."
