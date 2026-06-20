# Dollar Risk Spark Job
#
# Base image bundles Spark 3.5 + Iceberg runtime + iceberg-aws-bundle (S3FileIO).
# Check https://hub.docker.com/r/tabulario/spark-iceberg/tags for available tags.
FROM tabulario/spark-iceberg:3.5.5_1.8.1

COPY dollar_risk_job.py /home/iceberg/dollar_risk_job.py

# Default catalog/schema; override with -e at runtime or in the K8s Job manifest.
ENV CATALOG=prod \
    SCHEMA=spark_risk

# Connection env vars must be supplied at runtime (see k8s-job.yaml):
#   POLARIS_OAUTH_CREDENTIAL, POLARIS_CATALOG_URI
#   S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY

ENTRYPOINT ["/opt/spark/bin/spark-submit", \
    "--master", "local[*]", \
    "/home/iceberg/dollar_risk_job.py"]
