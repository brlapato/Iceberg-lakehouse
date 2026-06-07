# Environment: rsch-lake
# Deploy with: make all ENV=rsch-lake

NAMESPACE           := rsch-lake

S3_ACCESS_KEY       := lakehouse-access-key
S3_SECRET_KEY       := lakehouse-secret-key
S3_REGION           := us-east-1
S3_BUCKET           := warehouse

POLARIS_REALM       := POLARIS
POLARIS_ROOT_ID     := root
POLARIS_ROOT_SECRET := polaris-dev-secret
