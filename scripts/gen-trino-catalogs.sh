#!/usr/bin/env bash
# Generate Helm values YAML for all Trino/Iceberg catalogs.
# Outputs to stdout; captured by `make trino` and passed as --values.
#
# Env vars:
#   CATALOGS   space-separated catalog names (each becomes a Trino + Polaris catalog)
#
# The catalog properties use ${ENV:*} placeholders that Trino substitutes at
# startup from pod environment variables (injected from K8s secrets/ConfigMap).

set -euo pipefail

CATALOGS="${CATALOGS:?CATALOGS is required}"

echo "catalogs:"

for catalog in ${CATALOGS}; do
    cat <<EOF
  ${catalog}: |
    connector.name=iceberg
    iceberg.catalog.type=rest
    iceberg.rest-catalog.uri=\${ENV:POLARIS_CATALOG_URI}
    iceberg.rest-catalog.warehouse=${catalog}
    iceberg.rest-catalog.security=OAUTH2
    iceberg.rest-catalog.oauth2.credential=\${ENV:POLARIS_OAUTH_CREDENTIAL}
    iceberg.rest-catalog.oauth2.scope=PRINCIPAL_ROLE:ALL
    iceberg.target-max-file-size=128MB
    iceberg.unique-table-location=true
    fs.native-s3.enabled=true
    s3.endpoint=\${ENV:S3_ENDPOINT}
    s3.region=us-east-1
    s3.path-style-access=true
    s3.aws-access-key=\${ENV:S3_ACCESS_KEY}
    s3.aws-secret-key=\${ENV:S3_SECRET_KEY}
EOF
done
