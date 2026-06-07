#!/usr/bin/env bash
# Ranger Admin entrypoint:
#   1. Waits for MySQL to accept connections.
#   2. Runs setup.sh once if ranger_db schema is not yet initialized.
#   3. Starts the Ranger Admin server in the foreground (tails the log).
set -euo pipefail

DB_HOST="${DB_HOST:-mysql}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-password}"
DB_NAME="${DB_NAME:-ranger_db}"
DB_USER="${DB_USER:-ranger_user}"
DB_PASSWORD="${DB_PASSWORD:-ranger_password}"
RANGER_ADMIN_PASSWORD="${RANGER_ADMIN_PASSWORD:-RangerAdmin1!}"
POLICYMGR_URL="${POLICYMGR_URL:-http://ranger.lakehouse.svc.cluster.local:6080}"

MYSQL="mysql -h ${DB_HOST} -u root -p${DB_ROOT_PASSWORD} --connect-timeout=5"

log() { echo "[ranger-entrypoint] $*"; }

# ---------------------------------------------------------------------------
# 1. Wait for MySQL
# ---------------------------------------------------------------------------
log "Waiting for MySQL at ${DB_HOST}..."
until $MYSQL -e "SELECT 1" >/dev/null 2>&1; do
    sleep 3
done
log "MySQL is up."

# ---------------------------------------------------------------------------
# 2. Run setup if conf directory is not yet configured.
# setup.sh is idempotent: it skips already-applied DB patches, so it is safe
# to run on every container start. The conf/ dir exists only after setup runs.
# ---------------------------------------------------------------------------
CONF_DIR=/opt/ranger-admin/ews/webapp/WEB-INF/classes/conf
if [[ ! -d "$CONF_DIR" ]]; then
    log "Running Ranger setup (conf directory not found)..."

    # Start from the default install.properties (has all required path variables)
    # and patch only the fields we need to override.
    cp /opt/ranger-admin/install.properties /opt/ranger-admin/install.properties.bak
    sed -i \
        -e "s|^SQL_CONNECTOR_JAR=.*|SQL_CONNECTOR_JAR=/opt/ranger-admin/jisql/lib/mysql-connector-j-8.0.33.jar|" \
        -e "s|^db_root_password=.*|db_root_password=${DB_ROOT_PASSWORD}|" \
        -e "s|^db_host=.*|db_host=${DB_HOST}|" \
        -e "s|^db_name=.*|db_name=${DB_NAME}|" \
        -e "s|^db_user=.*|db_user=${DB_USER}|" \
        -e "s|^db_password=.*|db_password=${DB_PASSWORD}|" \
        -e "s|^is_override_db_connection_string=.*|is_override_db_connection_string=true|" \
        -e "s|^db_override_connection_string=.*|db_override_connection_string=jdbc:mysql://${DB_HOST}/${DB_NAME}?useSSL=false\&allowPublicKeyRetrieval=true|" \
        -e "s|^audit_store=.*|audit_store=|" \
        -e "s|^policymgr_external_url=.*|policymgr_external_url=${POLICYMGR_URL}|" \
        -e "s|^unix_user_pwd=.*|unix_user_pwd=ranger1234|" \
        -e "s|^rangerAdmin_password=.*|rangerAdmin_password=${RANGER_ADMIN_PASSWORD}|" \
        -e "s|^rangerTagsync_password=.*|rangerTagsync_password=RangerTagSync1!|" \
        -e "s|^rangerUsersync_password=.*|rangerUsersync_password=RangerUserSync1!|" \
        -e "s|^keyadmin_password=.*|keyadmin_password=KeyAdmin1!|" \
        /opt/ranger-admin/install.properties

    # Patch JDBC URLs in setup Python scripts to allow public key retrieval
    # (required by MySQL 8.x caching_sha2_password auth plugin)
    sed -i 's/useSSL=false"/useSSL=false\&allowPublicKeyRetrieval=true"/g' \
        /opt/ranger-admin/db_setup.py \
        /opt/ranger-admin/dba_script.py

    cd /opt/ranger-admin
    bash setup.sh 2>&1 | tee /tmp/ranger-setup.log
    log "Setup complete."
else
    log "Ranger DB already initialized, skipping setup."
fi

# ---------------------------------------------------------------------------
# 3. Start Ranger Admin (daemonized), then tail log to keep container alive
# ---------------------------------------------------------------------------
log "Starting Ranger Admin on port 6080..."
mkdir -p /opt/ranger-admin/ews/logs
cd /opt/ranger-admin
bash ews/ranger-admin-services.sh start 2>&1

# Give the server a moment to create its log
sleep 3

LOG_FILE=/opt/ranger-admin/ews/logs/catalina.out
if [[ -f "$LOG_FILE" ]]; then
    log "Tailing $LOG_FILE (Ctrl-C to stop container)"
    exec tail -f "$LOG_FILE"
else
    log "Log not at expected path, waiting..."
    exec sleep infinity
fi
