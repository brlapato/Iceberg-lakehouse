# Environment: dev — example parallel environment
# Deploy with: make all ENV=dev
# Deploys to its own namespace so it coexists with the lakehouse environment.

NAMESPACE           := dev

S3_ACCESS_KEY       := dev-access-key
S3_SECRET_KEY       := dev-secret-key
S3_REGION           := us-east-1

POLARIS_REALM       := POLARIS
POLARIS_ROOT_ID     := root
POLARIS_ROOT_SECRET := dev-polaris-secret

CATALOGS                  := warehouse
CATALOG_warehouse_BUCKET  := warehouse
