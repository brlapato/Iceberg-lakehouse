# Environment: rsch-lake
# Deploy with: make all ENV=rsch-lake

NAMESPACE           := rsch-lake

S3_ACCESS_KEY       := lakehouse-access-key
S3_SECRET_KEY       := lakehouse-secret-key
S3_REGION           := us-east-1

POLARIS_REALM       := POLARIS
POLARIS_ROOT_ID     := root
POLARIS_ROOT_SECRET := polaris-dev-secret

CATALOGS                  := rsch prod
CATALOG_rsch_BUCKET       := shared-lake-bucket
CATALOG_prod_BUCKET       := shared-lake-bucket

# Keycloak — JWT authentication for Trino (in-cluster OIDC)
# Keycloak is deployed in the 'auth' namespace via the keycloakx chart.
KEYCLOAK_URL   := http://keycloak-keycloakx-http.auth.svc.cluster.local/auth
KEYCLOAK_REALM := rsch-lake

# PositionService Keycloak client — used by notebooks and Superset→Trino auth.
KEYCLOAK_POSITION_SECRET := gNUiRyYesntJc0o1oOG15FkDhHHMk6X9

# Superset
SUPERSET_SECRET_KEY     := e962a322a84cc469d7043aedc0bbc7e94aa24ffb218ac3ecc91262324868ccbd
SUPERSET_ADMIN_PASSWORD := admin
SUPERSET_DB_PASSWORD    := superset-dev
