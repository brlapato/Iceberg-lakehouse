#!/usr/bin/env bash
# Generate Helm values YAML for SeaweedFS s3.createBuckets.
# Outputs to stdout; captured by `make seaweedfs` and passed as --values.
#
# Env vars:
#   CATALOGS               space-separated catalog names
#   CATALOG_<name>_BUCKET  S3 bucket for each catalog

set -euo pipefail

CATALOGS="${CATALOGS:?CATALOGS is required}"

echo "s3:"
echo "  createBuckets:"

declare -A seen
for catalog in ${CATALOGS}; do
    bucket_var="CATALOG_${catalog}_BUCKET"
    bucket="${!bucket_var:-${catalog}}"
    if [[ -z "${seen[${bucket}]+x}" ]]; then
        echo "  - name: ${bucket}"
        echo "    anonymousRead: false"
        seen["${bucket}"]=1
    fi
done
