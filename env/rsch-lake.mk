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
