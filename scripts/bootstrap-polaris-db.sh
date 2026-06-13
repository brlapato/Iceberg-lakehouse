#!/usr/bin/env bash
# Applies the Polaris PostgreSQL schema and bootstraps the POLARIS realm.
# Idempotent: schema uses IF NOT EXISTS; bootstrap is skipped if already done.
#
# Required env vars:
#   NAMESPACE         — Kubernetes namespace
#   POLARIS_DB_PASSWORD — PostgreSQL password for the polaris user

set -euo pipefail

NAMESPACE="${NAMESPACE:?NAMESPACE is required}"
POLARIS_DB_PASSWORD="${POLARIS_DB_PASSWORD:?POLARIS_DB_PASSWORD is required}"
JOB_NAME="polaris-db-init"
POLARIS_IMAGE="apache/polaris:1.5.0"

_psql() {
    kubectl exec -n "${NAMESPACE}" statefulset/polaris-postgresql -- \
        env PGPASSWORD="${POLARIS_DB_PASSWORD}" psql -U polaris -d polaris "$@"
}

# Fast-path: skip everything if realm is already bootstrapped.
COUNT=$(_psql -t -A -c "SELECT COUNT(*) FROM polaris_schema.entities" 2>/dev/null \
    | tr -d '[:space:]' || echo "0")
if [ "${COUNT}" -gt "0" ] 2>/dev/null; then
    echo "[bootstrap-polaris-db] Realm already bootstrapped (${COUNT} entities). Skipping."
    exit 0
fi

echo "[bootstrap-polaris-db] Bootstrapping Polaris PostgreSQL schema and realm..."

# Delete any leftover job from a previous failed run.
kubectl delete job "${JOB_NAME}" --namespace="${NAMESPACE}" --ignore-not-found 2>/dev/null

# One Job with two init containers (schema extraction + application) followed
# by the Polaris bootstrap server (which never exits on its own).
# The script polls PostgreSQL and deletes the Job once the realm is in the DB.
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  template:
    spec:
      restartPolicy: Never
      volumes:
        - name: schema
          emptyDir: {}
      initContainers:
        # 1. Extract schema SQL from the Polaris JAR into a shared volume.
        - name: extract-schema
          image: ${POLARIS_IMAGE}
          command:
            - python3
            - -c
            - |
              import zipfile
              jar = '/deployments/lib/main/org.apache.polaris.polaris-relational-jdbc-1.5.0.jar'
              z = zipfile.ZipFile(jar)
              # Apply schema-v4.sql only (full schema, not incremental migrations).
              # Applying v1 then v2/v3/v4 would leave entities missing later columns
              # because CREATE TABLE IF NOT EXISTS skips the upgraded column list.
              with open('/schema/schema.sql', 'w') as f:
                  f.write(z.read('postgres/schema-v4.sql').decode())
          volumeMounts:
            - name: schema
              mountPath: /schema
        # 2. Apply the schema SQL to PostgreSQL (IF NOT EXISTS, idempotent).
        - name: apply-schema
          image: postgres:15-alpine
          command: [psql, -f, /schema/schema.sql, -q]
          env:
            - {name: PGHOST,     value: polaris-postgresql}
            - {name: PGPORT,     value: "5432"}
            - {name: PGDATABASE, value: polaris}
            - {name: PGUSER,     value: polaris}
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: polaris-jdbc-credentials
                  key: password
          volumeMounts:
            - name: schema
              mountPath: /schema
      containers:
        # 3. Start Polaris in bootstrap mode so it writes the root principal
        #    and realm credentials into polaris_schema.entities.
        #    POLARIS_PERSISTENCE_AUTO_BOOTSTRAP_TYPES overrides the default
        #    (in-memory only) to include relational-jdbc.
        - name: bootstrap
          image: ${POLARIS_IMAGE}
          command: [java, -XX:MaxRAMPercentage=80.0, -XX:+UseParallelGC, -cp, ., -jar, /deployments/quarkus-run.jar]
          env:
            - {name: POLARIS_PERSISTENCE_TYPE, value: relational-jdbc}
            - {name: POLARIS_PERSISTENCE_AUTO_BOOTSTRAP_TYPES, value: "relational-jdbc,in-memory"}
            - name: quarkus.datasource.username
              valueFrom:
                secretKeyRef: {name: polaris-jdbc-credentials, key: username}
            - name: quarkus.datasource.password
              valueFrom:
                secretKeyRef: {name: polaris-jdbc-credentials, key: password}
            - name: quarkus.datasource.jdbc.url
              valueFrom:
                secretKeyRef: {name: polaris-jdbc-credentials, key: jdbcUrl}
            - name: POLARIS_BOOTSTRAP_CREDENTIALS
              valueFrom:
                secretKeyRef: {name: polaris-bootstrap-credentials, key: credentials}
            - {name: AWS_REGION, value: "us-east-1"}
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef: {name: s3-credentials, key: access-key}
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef: {name: s3-credentials, key: secret-key}
            - name: AWS_ENDPOINT_URL_S3
              valueFrom:
                configMapKeyRef: {name: lakehouse-config, key: s3-endpoint}
EOF

# The bootstrap container never exits, so we poll the DB instead of waiting
# for the Job to complete. Timeout: 36 × 5 s = 3 minutes.
echo "[bootstrap-polaris-db] Waiting for realm bootstrap (polling DB, up to 3 min)..."
for i in $(seq 1 36); do
    sleep 5
    COUNT=$(_psql -t -A -c "SELECT COUNT(*) FROM polaris_schema.entities" 2>/dev/null \
        | tr -d '[:space:]' || echo "0")
    if [ "${COUNT:-0}" -gt 0 ] 2>/dev/null; then
        echo "[bootstrap-polaris-db] Realm bootstrapped (${COUNT} entities in DB)."
        break
    fi
    if [ "$i" -eq 36 ]; then
        echo "[bootstrap-polaris-db] ERROR: Bootstrap timed out after 3 minutes." >&2
        kubectl logs -n "${NAMESPACE}" -l job-name="${JOB_NAME}" --tail=30 2>&1 || true
        kubectl delete job "${JOB_NAME}" --namespace="${NAMESPACE}" --ignore-not-found
        exit 1
    fi
done

kubectl delete job "${JOB_NAME}" --namespace="${NAMESPACE}" --ignore-not-found
echo "[bootstrap-polaris-db] Done."
