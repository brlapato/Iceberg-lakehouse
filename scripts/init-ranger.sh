#!/usr/bin/env bash
# Bootstrap Ranger Admin after Helm deployment:
#   1. Wait for Ranger Admin to become healthy.
#   2. Create the Trino service definition.
#   3. Create initial access policies.
#
# Usage: NAMESPACE=lakehouse bash scripts/init-ranger.sh

set -euo pipefail

NAMESPACE="${NAMESPACE:-lakehouse}"
RANGER_ADMIN_USER="admin"
RANGER_ADMIN_PASS="RangerAdmin1!"
RANGER_PORT=6380   # local port-forward (avoid conflict with 6080 if already in use)
RANGER_BASE="http://localhost:${RANGER_PORT}"

# Read configurable values from the lakehouse-config ConfigMap
cm() { kubectl get configmap lakehouse-config -n "$NAMESPACE" -o "jsonpath={.data.$1}"; }
RANGER_SERVICE_NAME=$(cm RANGER_SERVICE_NAME)
TRINO_SVC_URL="jdbc:trino://trino.${NAMESPACE}.svc.cluster.local:8443/lakehouse"

log() { echo "[init-ranger] $*"; }

# ---------------------------------------------------------------------------
# Port-forward Ranger Admin
# ---------------------------------------------------------------------------
log "Starting port-forward localhost:${RANGER_PORT} -> ranger:6080..."
kubectl port-forward svc/ranger --namespace "$NAMESPACE" "${RANGER_PORT}:6080" &>/tmp/pf-ranger-init.log &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null; wait $PF_PID 2>/dev/null || true; log "Port-forward stopped"' EXIT

# ---------------------------------------------------------------------------
# Wait for Ranger Admin to accept requests
# ---------------------------------------------------------------------------
log "Waiting for Ranger Admin to become ready..."
python3 - <<'PYEOF'
import urllib.request, time, sys

deadline = time.time() + 300
while time.time() < deadline:
    try:
        with urllib.request.urlopen("http://localhost:6380/login.jsp", timeout=5) as r:
            if r.status == 200:
                print("[init-ranger] Ranger Admin is up.")
                sys.exit(0)
    except Exception:
        pass
    time.sleep(5)

print("[init-ranger] ERROR: Ranger Admin did not become ready within 5 minutes", file=sys.stderr)
sys.exit(1)
PYEOF

# ---------------------------------------------------------------------------
# Helper: call Ranger Admin REST API
# ---------------------------------------------------------------------------
ranger_api() {
    local method="$1" path="$2" data="${3:-}"
    python3 - "$method" "$path" "$data" "$RANGER_ADMIN_USER" "$RANGER_ADMIN_PASS" "$RANGER_BASE" <<'PYEOF'
import sys, json, urllib.request, urllib.error, base64

method, path, data, user, pwd, base = sys.argv[1:]
url = f"{base}/service/public/v2/api{path}"
auth = base64.b64encode(f"{user}:{pwd}".encode()).decode()
headers = {
    "Authorization": f"Basic {auth}",
    "Content-Type": "application/json",
    "Accept": "application/json",
}
body = data.encode() if data else None
req = urllib.request.Request(url, data=body, headers=headers, method=method)
try:
    with urllib.request.urlopen(req) as r:
        result = json.loads(r.read() or b'{}')
        print(json.dumps(result))
        sys.exit(0)
except urllib.error.HTTPError as e:
    body = e.read().decode()
    if e.code == 400 and ("already exists" in body or "duplicate" in body.lower()):
        print(json.dumps({"_skipped": True, "message": body[:120]}))
        sys.exit(0)
    print(f"HTTP {e.code}: {body[:300]}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# ---------------------------------------------------------------------------
# 1. Create Trino service in Ranger
# ---------------------------------------------------------------------------
log "Creating Trino service in Ranger..."

TRINO_SVC_PAYLOAD=$(python3 -c "
import json, sys
svc_name, jdbc_url = sys.argv[1], sys.argv[2]
print(json.dumps({
    'name': svc_name,
    'displayName': 'Trino Lakehouse',
    'type': 'trino',
    'description': 'Trino service for the lakehouse stack',
    'configs': {
        'username': 'admin',
        'jdbc.driverClassName': 'io.trino.jdbc.TrinoDriver',
        'jdbc.url': jdbc_url,
    }
}))
" "$RANGER_SERVICE_NAME" "$TRINO_SVC_URL")

RESULT=$(ranger_api POST /service "$TRINO_SVC_PAYLOAD")
if python3 -c "import sys,json; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('_skipped') else 1)" "$RESULT" 2>/dev/null; then
    log "Service '${RANGER_SERVICE_NAME}' already exists — skipping."
else
    SVC_ID=$(python3 -c "import sys,json; print(json.loads(sys.argv[1]).get('id','?'))" "$RESULT")
    log "Service '${RANGER_SERVICE_NAME}' created (id=$SVC_ID)."
fi

# ---------------------------------------------------------------------------
# 2. Policy: admin user has full access to all catalogs
# ---------------------------------------------------------------------------
log "Creating admin-all policy..."

ADMIN_POLICY=$(python3 -c "
import json, sys
svc_name = sys.argv[1]
print(json.dumps({
    'name': 'admin-all',
    'service': svc_name,
    'description': 'Admin user has unrestricted access to all catalogs',
    'isEnabled': True,
    'isAuditEnabled': True,
    'resources': {
        'catalog': {'values': ['*'], 'isRecursive': False, 'isExcludes': False},
        'schema':  {'values': ['*'], 'isRecursive': False, 'isExcludes': False},
        'table':   {'values': ['*'], 'isRecursive': False, 'isExcludes': False},
    },
    'policyItems': [{
        'users': ['admin'],
        'accesses': [
            {'type': 'select', 'isAllowed': True},
            {'type': 'insert', 'isAllowed': True},
            {'type': 'update', 'isAllowed': True},
            {'type': 'delete', 'isAllowed': True},
            {'type': 'use',    'isAllowed': True},
            {'type': 'create', 'isAllowed': True},
            {'type': 'drop',   'isAllowed': True},
            {'type': 'alter',  'isAllowed': True},
        ],
        'delegateAdmin': True,
    }],
}))
" "$RANGER_SERVICE_NAME")

RESULT=$(ranger_api POST /policy "$ADMIN_POLICY")
python3 -c "import sys,json; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('_skipped') else 1)" "$RESULT" 2>/dev/null \
    && log "Policy 'admin-all' already exists." \
    || log "Policy 'admin-all' created."

# ---------------------------------------------------------------------------
# 3. Policy: all authenticated users can read tpch (demo catalog)
# ---------------------------------------------------------------------------
log "Creating tpch-public policy..."

TPCH_POLICY=$(python3 -c "
import json, sys
svc_name = sys.argv[1]
print(json.dumps({
    'name': 'tpch-public',
    'service': svc_name,
    'description': 'All authenticated users can read the tpch sample catalog',
    'isEnabled': True,
    'isAuditEnabled': True,
    'resources': {
        'catalog': {'values': ['tpch'], 'isRecursive': False, 'isExcludes': False},
        'schema':  {'values': ['*'],    'isRecursive': False, 'isExcludes': False},
        'table':   {'values': ['*'],    'isRecursive': False, 'isExcludes': False},
    },
    'policyItems': [{
        'groups': ['public'],
        'accesses': [
            {'type': 'select', 'isAllowed': True},
            {'type': 'use',    'isAllowed': True},
        ],
        'delegateAdmin': False,
    }],
}))
" "$RANGER_SERVICE_NAME")

RESULT=$(ranger_api POST /policy "$TPCH_POLICY")
python3 -c "import sys,json; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('_skipped') else 1)" "$RESULT" 2>/dev/null \
    && log "Policy 'tpch-public' already exists." \
    || log "Policy 'tpch-public' created."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log ""
log "Ranger Admin bootstrapped."
log "  Service:  ${RANGER_SERVICE_NAME}"
log "  Policies: admin-all, tpch-public"
log ""
log "Access Ranger Admin UI:"
log "  make pf-ranger        →  http://localhost:6080"
log "  Login: admin / ${RANGER_ADMIN_PASS}"
