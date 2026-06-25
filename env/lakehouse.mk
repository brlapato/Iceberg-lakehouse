# Environment: lakehouse — default dev environment (minikube single-node)
# Included by the Makefile. Copy and edit to add a new environment.
# Deploy with: make all            (uses this file by default)
#              make all ENV=dev    (uses env/dev.mk)

NAMESPACE           := lakehouse

# Pin to the existing release name so the running deployment is not disrupted.
# New environments omit this and get seaweedfs-<NAMESPACE> automatically.
SEAWEEDFS_RELEASE   := seaweedfs

# S3 credentials for SeaweedFS — also referenced by Polaris and Trino via K8s secret
S3_ACCESS_KEY       := lakehouse-access-key
S3_SECRET_KEY       := lakehouse-secret-key
S3_REGION           := us-east-1

# Polaris bootstrap credentials (root principal used by init-polaris.sh)
POLARIS_REALM       := POLARIS
POLARIS_ROOT_ID     := root
POLARIS_ROOT_SECRET := polaris-dev-secret

# ---------------------------------------------------------------------------
# Catalogs — each entry becomes a Polaris catalog + Trino catalog.
# CATALOGS     : space-separated list of catalog names
# CATALOG_<n>_BUCKET : S3 bucket backing that catalog
# ---------------------------------------------------------------------------
CATALOGS                  := warehouse prod
CATALOG_warehouse_BUCKET  := warehouse
CATALOG_prod_BUCKET       := warehouse

# PositionService Keycloak client — used by notebooks and Superset→Trino auth.
KEYCLOAK_POSITION_SECRET := gNUiRyYesntJc0o1oOG15FkDhHHMk6X9

# Superset
SUPERSET_SECRET_KEY     := e962a322a84cc469d7043aedc0bbc7e94aa24ffb218ac3ecc91262324868ccbd
SUPERSET_ADMIN_PASSWORD := admin
SUPERSET_DB_PASSWORD    := superset-dev
