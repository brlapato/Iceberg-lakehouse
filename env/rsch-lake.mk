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
