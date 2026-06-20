#!/usr/bin/env python3
"""
Dollar Risk Spark Job

Reads prod.spark_risk.prices and prod.spark_risk.positions from Iceberg,
computes:
    dollar_risk = stddev(close, 21-day rolling window) * |position| * close

Overwrites prod.spark_risk.dollar_risk with the results.

Required environment variables:
    POLARIS_OAUTH_CREDENTIAL  Polaris client_id:client_secret
    POLARIS_CATALOG_URI       http://polaris.<ns>.svc.cluster.local:8181/api/catalog
    S3_ENDPOINT               http://seaweedfs-<ns>-s3.<ns>.svc.cluster.local:8333
    S3_ACCESS_KEY             SeaweedFS access key
    S3_SECRET_KEY             SeaweedFS secret key

Optional:
    CATALOG                   Iceberg catalog name   (default: prod)
    SCHEMA                    Schema name            (default: spark_risk)
"""

import os
from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql.window import Window


def build_session(catalog, polaris_uri, credential, s3_endpoint, s3_key, s3_secret):
    return (
        SparkSession.builder
        .appName("dollar-risk")
        # Iceberg REST catalog pointing at Polaris
        .config(f"spark.sql.catalog.{catalog}",               "org.apache.iceberg.spark.SparkCatalog")
        .config(f"spark.sql.catalog.{catalog}.catalog-impl",  "org.apache.iceberg.rest.RESTCatalog")
        .config(f"spark.sql.catalog.{catalog}.uri",           polaris_uri)
        .config(f"spark.sql.catalog.{catalog}.warehouse",     catalog)
        .config(f"spark.sql.catalog.{catalog}.credential",    credential)
        .config(f"spark.sql.catalog.{catalog}.scope",         "PRINCIPAL_ROLE:ALL")
        # Use Iceberg's S3FileIO directly (avoids Hadoop S3A, same as Trino's
        # vended-credentials-enabled=false — uses static keys, not STS)
        .config(f"spark.sql.catalog.{catalog}.io-impl",                 "org.apache.iceberg.aws.s3.S3FileIO")
        .config(f"spark.sql.catalog.{catalog}.s3.endpoint",             s3_endpoint)
        .config(f"spark.sql.catalog.{catalog}.s3.access-key-id",        s3_key)
        .config(f"spark.sql.catalog.{catalog}.s3.secret-access-key",    s3_secret)
        .config(f"spark.sql.catalog.{catalog}.s3.path-style-access",    "true")
        # Region for DefaultAwsClientFactory — AwsClientProperties reads "client.region",
        # not "s3.region". Without this the SDK falls back to DefaultAwsRegionProviderChain
        # which fails outside AWS (no EC2 metadata, no env var, no profile).
        .config(f"spark.sql.catalog.{catalog}.client.region",           "us-east-1")
        .config(
            "spark.sql.extensions",
            "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
        )
        # The tabulario image pre-configures spark_catalog to point at http://rest:8181
        # (its bundled demo server). Override the default catalog so Spark never tries
        # to initialize spark_catalog.
        .config("spark.sql.defaultCatalog", catalog)
        .getOrCreate()
    )


def compute_dollar_risk(spark, catalog, schema):
    prices    = spark.table(f"{catalog}.{schema}.prices")
    positions = spark.table(f"{catalog}.{schema}.positions")

    # 21-day rolling window ordered by trade_date within each market.
    # rowsBetween(-20, 0) gives the current row plus the 20 preceding rows.
    w21 = (
        Window
        .partitionBy("market")
        .orderBy(F.col("trade_date").cast("long"))
        .rowsBetween(-20, 0)
    )

    prices_vol = prices.withColumn("vol_21d", F.stddev("close").over(w21))

    joined = prices_vol.join(positions, on=["trade_date", "market"])

    dollar_risk = (
        joined
        .withColumn(
            "dollar_risk",
            F.round(
                F.col("vol_21d") * F.abs(F.col("position")) * F.col("close"),
                4,
            ),
        )
        .select("trade_date", "market", "dollar_risk")
        .dropna(subset=["dollar_risk"])   # first 20 rows per market have no vol
    )

    return dollar_risk


def main():
    catalog     = os.environ.get("CATALOG", "prod")
    schema      = os.environ.get("SCHEMA",  "spark_risk")
    polaris_uri = os.environ["POLARIS_CATALOG_URI"]
    credential  = os.environ["POLARIS_OAUTH_CREDENTIAL"]
    s3_endpoint = os.environ["S3_ENDPOINT"]
    s3_key      = os.environ["S3_ACCESS_KEY"]
    s3_secret   = os.environ["S3_SECRET_KEY"]

    spark = build_session(catalog, polaris_uri, credential, s3_endpoint, s3_key, s3_secret)
    spark.sparkContext.setLogLevel("WARN")

    print(f"Reading {catalog}.{schema}.prices and {catalog}.{schema}.positions ...")
    result = compute_dollar_risk(spark, catalog, schema)

    row_count = result.count()
    print(f"Computed {row_count:,} dollar_risk rows.")

    print(f"Writing to {catalog}.{schema}.dollar_risk ...")
    result.writeTo(f"{catalog}.{schema}.dollar_risk").overwritePartitions()

    print("Done.")
    spark.stop()


if __name__ == "__main__":
    main()
