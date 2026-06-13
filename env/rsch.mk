# Environment: dev — example parallel environment
# Deploy with: make all ENV=dev
# Deploys to its own namespace so it coexists with the lakehouse environment.

NAMESPACE           := rsch-lake

S3_ACCESS_KEY       := rsch-access-key
S3_SECRET_KEY       := rsch-secret-key
S3_REGION           := us-east-1
S3_BUCKET           := rsch

POLARIS_REALM       := POLARIS
POLARIS_ROOT_ID     := root
POLARIS_ROOT_SECRET := rsch-polaris-secret
