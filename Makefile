ENV ?= lakehouse

# Load environment-specific settings (namespace, credentials, catalogs, etc.)
include env/$(ENV).mk

# Polaris PostgreSQL password — override per environment in env/<ENV>.mk if needed.
POLARIS_DB_PASSWORD ?= polaris-dev

# Keycloak JWT auth for Trino — set both in env/<ENV>.mk to enable.
# When KEYCLOAK_URL is empty the trino target deploys without authentication.
KEYCLOAK_URL   ?=
KEYCLOAK_REALM ?=

HELM    := helm
KUBECTL := kubectl

# Superset runs in its own namespace so its PostgreSQL and Redis sub-charts are
# isolated from the lakehouse services and can be torn down independently.
SUPERSET_NAMESPACE ?= superset

# SeaweedFS release name — must be unique across environments because the chart
# creates cluster-scoped ClusterRole/ClusterRoleBinding named <release>-rw-cr(b).
# Defaults to seaweedfs-<NAMESPACE>; env/*.mk can override (lakehouse pins to
# "seaweedfs" to preserve its existing release without reinstalling).
SEAWEEDFS_RELEASE ?= seaweedfs-$(NAMESPACE)

# Derived service endpoints — update automatically with NAMESPACE / SEAWEEDFS_RELEASE
S3_SVC_NAME         := $(SEAWEEDFS_RELEASE)-s3
S3_HOST             := $(S3_SVC_NAME).$(NAMESPACE).svc.cluster.local
S3_ENDPOINT         := http://$(S3_HOST):8333
POLARIS_HOST        := polaris.$(NAMESPACE).svc.cluster.local
POLARIS_CATALOG_URI := http://$(POLARIS_HOST):8181/api/catalog
POLARIS_BOOTSTRAP   := $(POLARIS_REALM),$(POLARIS_ROOT_ID),$(POLARIS_ROOT_SECRET)

# CATALOG_ENV_VARS: shell assignments for each catalog's bucket variable.
# Expands to e.g.: CATALOG_warehouse_BUCKET='warehouse' CATALOG_research_BUCKET='research-data'
# Passed to scripts so they can resolve bucket names per catalog.
CATALOG_ENV_VARS := $(foreach c,$(CATALOGS),CATALOG_$(c)_BUCKET='$(CATALOG_$(c)_BUCKET)')

.PHONY: all repos namespaces credentials config seaweedfs postgresql-polaris polaris trino \
        openmetadata-deps openmetadata superset init-storage register-tables \
        add-catalog status teardown \
        pf-trino pf-polaris pf-openmetadata pf-seaweedfs-s3 pf-superset

# Deploy everything in dependency order
all: repos namespaces credentials config seaweedfs postgresql-polaris polaris trino openmetadata-deps openmetadata superset

# ---------------------------------------------------------------------------
# Helm repository setup
# ---------------------------------------------------------------------------
repos:
	$(HELM) repo add seaweedfs      https://seaweedfs.github.io/seaweedfs/helm
	$(HELM) repo add polaris        https://downloads.apache.org/polaris/helm-chart
	$(HELM) repo add trino          https://trinodb.github.io/charts
	$(HELM) repo add open-metadata  https://helm.open-metadata.org
	$(HELM) repo add bitnami        https://charts.bitnami.com/bitnami
	$(HELM) repo add superset       https://apache.github.io/superset
	$(HELM) repo update

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
namespaces:
	$(KUBECTL) create namespace $(NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f -

# ---------------------------------------------------------------------------
# Shared K8s secrets and ConfigMap — all env-specific values live here.
# Run before deploying any chart that references these resources.
# ---------------------------------------------------------------------------
credentials: namespaces
	# SeaweedFS gateway auth config (JSON format required by the chart)
	$(KUBECTL) create secret generic seaweedfs-s3-credentials \
		--namespace $(NAMESPACE) \
		--from-literal='seaweedfs_s3_config={"identities":[{"name":"admin","credentials":[{"accessKey":"$(S3_ACCESS_KEY)","secretKey":"$(S3_SECRET_KEY)"}],"actions":["Admin","Read","ReadAcp","Write","WriteAcp"]}]}' \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -
	# Flat S3 credentials — referenced by Polaris and Trino via secretKeyRef
	$(KUBECTL) create secret generic s3-credentials \
		--namespace $(NAMESPACE) \
		--from-literal=access-key=$(S3_ACCESS_KEY) \
		--from-literal=secret-key=$(S3_SECRET_KEY) \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -
	# Polaris root principal credentials (REALM,CLIENT_ID,CLIENT_SECRET format)
	$(KUBECTL) create secret generic polaris-bootstrap-credentials \
		--namespace $(NAMESPACE) \
		--from-literal=credentials=$(POLARIS_BOOTSTRAP) \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -
	# Polaris PostgreSQL JDBC credentials — consumed by Polaris (persistence) and
	# also used as the bitnami/postgresql auth password via --set at deploy time.
	$(KUBECTL) create secret generic polaris-jdbc-credentials \
		--namespace $(NAMESPACE) \
		--from-literal=username=polaris \
		--from-literal=password=$(POLARIS_DB_PASSWORD) \
		--from-literal=jdbcUrl=jdbc:postgresql://polaris-postgresql:5432/polaris \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -

config: namespaces
	# Service endpoints — consumed by Polaris and Trino via configMapKeyRef
	$(KUBECTL) create configmap lakehouse-config \
		--namespace $(NAMESPACE) \
		--from-literal=s3-endpoint=$(S3_ENDPOINT) \
		--from-literal=polaris-catalog-uri=$(POLARIS_CATALOG_URI) \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -

# ---------------------------------------------------------------------------
# SeaweedFS — object storage (S3-compatible)
# Generates an s3.createBuckets values overlay from CATALOGS before install.
# ---------------------------------------------------------------------------
seaweedfs: namespaces credentials
	CATALOGS='$(CATALOGS)' $(CATALOG_ENV_VARS) \
		bash scripts/gen-seaweedfs-buckets.sh > /tmp/seaweedfs-buckets-$(ENV).yaml
	$(HELM) upgrade --install $(SEAWEEDFS_RELEASE) seaweedfs/seaweedfs \
		--namespace $(NAMESPACE) \
		--values seaweedfs/values.yaml \
		--values /tmp/seaweedfs-buckets-$(ENV).yaml \
		--set s3.domainName=$(S3_HOST) \
		--wait --timeout 5m

# ---------------------------------------------------------------------------
# PostgreSQL — persistent backing store for Polaris catalog metadata
# ---------------------------------------------------------------------------
postgresql-polaris: namespaces credentials
	$(HELM) upgrade --install polaris-postgresql bitnami/postgresql \
		--namespace $(NAMESPACE) \
		--values polaris/postgresql-values.yaml \
		--set auth.password=$(POLARIS_DB_PASSWORD) \
		--wait --timeout 5m

# ---------------------------------------------------------------------------
# Apache Polaris — Iceberg REST Catalog (v1.5.0)
# Runs init-polaris.sh to bootstrap all catalogs defined in CATALOGS.
# Idempotent: existing catalogs and the trino principal are skipped/rotated.
# ---------------------------------------------------------------------------
polaris: namespaces credentials config postgresql-polaris
	# Bootstrap PostgreSQL schema + POLARIS realm before deploying the server.
	# Idempotent: no-op if realm already exists in the DB.
	NAMESPACE=$(NAMESPACE) POLARIS_DB_PASSWORD=$(POLARIS_DB_PASSWORD) \
		bash scripts/bootstrap-polaris-db.sh
	$(HELM) upgrade --install polaris polaris/polaris \
		--namespace $(NAMESPACE) \
		--version 1.5.0 \
		--values polaris/values.yaml \
		--wait --timeout 5m
	NAMESPACE=$(NAMESPACE) S3_SVC_NAME=$(S3_SVC_NAME) \
	CATALOGS='$(CATALOGS)' $(CATALOG_ENV_VARS) \
		bash scripts/patch-polaris-hosts.sh
	NAMESPACE=$(NAMESPACE) \
	POLARIS_ROOT_ID=$(POLARIS_ROOT_ID) \
	POLARIS_ROOT_SECRET=$(POLARIS_ROOT_SECRET) \
	CATALOGS='$(CATALOGS)' $(CATALOG_ENV_VARS) \
	S3_ENDPOINT=$(S3_ENDPOINT) \
		bash scripts/init-polaris.sh

# ---------------------------------------------------------------------------
# Trino — distributed SQL query engine
# Generates catalog property files from CATALOGS before install.
# Must run after 'polaris' so the polaris-trino-credentials secret exists.
# ---------------------------------------------------------------------------
trino: namespaces credentials config
	CATALOGS='$(CATALOGS)' \
		bash scripts/gen-trino-catalogs.sh > /tmp/trino-catalogs-$(ENV).yaml
	# If KEYCLOAK_URL is set, build the JWT auth overlay (chart manages the ConfigMap).
	@if [ -n "$(KEYCLOAK_URL)" ]; then \
		echo "[trino] Keycloak JWT auth enabled ($(KEYCLOAK_URL)/realms/$(KEYCLOAK_REALM))"; \
		KEYCLOAK_URL='$(KEYCLOAK_URL)' KEYCLOAK_REALM='$(KEYCLOAK_REALM)' NAMESPACE='$(NAMESPACE)' \
			bash scripts/gen-trino-auth.sh > /tmp/trino-auth-$(ENV).yaml; \
	fi
	$(HELM) upgrade --install trino trino/trino \
		--namespace $(NAMESPACE) \
		--values trino/values.yaml \
		--values /tmp/trino-catalogs-$(ENV).yaml \
		$(if $(KEYCLOAK_URL),--values /tmp/trino-auth-$(ENV).yaml) \
		--wait --timeout 5m

# ---------------------------------------------------------------------------
# Add a single catalog to an existing deployment without touching other catalogs.
#
# Usage: make add-catalog CATALOG=<name> [BUCKET=<s3-bucket>] [ENV=<env>]
#
# Steps:
#   1. Creates the S3 bucket in SeaweedFS (via init-storage.sh)
#   2. Creates the Polaris catalog and grants trino-role access (init-catalog.sh)
#   3. Re-patches Polaris hostAliases to include the new bucket hostname
#
# After this completes, add the catalog to env/<ENV>.mk and run 'make trino'.
# ---------------------------------------------------------------------------
add-catalog:
	@test -n "$(CATALOG)" || \
		(echo "Usage: make add-catalog CATALOG=<name> [BUCKET=<s3-bucket>] [ENV=<env>]"; exit 1)
	NAMESPACE=$(NAMESPACE) S3_SVC_NAME=$(S3_SVC_NAME) \
	S3_ACCESS_KEY=$(S3_ACCESS_KEY) S3_SECRET_KEY=$(S3_SECRET_KEY) \
	S3_BUCKET=$(or $(BUCKET),$(CATALOG)) \
		bash scripts/init-storage.sh
	NAMESPACE=$(NAMESPACE) \
	POLARIS_ROOT_ID=$(POLARIS_ROOT_ID) \
	POLARIS_ROOT_SECRET=$(POLARIS_ROOT_SECRET) \
	CATALOG_NAME=$(CATALOG) \
	S3_BUCKET=$(or $(BUCKET),$(CATALOG)) \
	S3_ENDPOINT=$(S3_ENDPOINT) \
		bash scripts/init-catalog.sh
	NAMESPACE=$(NAMESPACE) S3_SVC_NAME=$(S3_SVC_NAME) \
	CATALOGS='$(CATALOGS) $(CATALOG)' \
	$(CATALOG_ENV_VARS) \
	CATALOG_$(CATALOG)_BUCKET='$(or $(BUCKET),$(CATALOG))' \
		bash scripts/patch-polaris-hosts.sh
	@echo ""
	@echo "Catalog '$(CATALOG)' is ready in Polaris."
	@echo "Add to env/$(ENV).mk then run 'make trino ENV=$(ENV)':"
	@echo "  CATALOGS += $(CATALOG)"
	@echo "  CATALOG_$(CATALOG)_BUCKET := $(or $(BUCKET),$(CATALOG))"

# ---------------------------------------------------------------------------
# OpenMetadata — metadata management platform
# ---------------------------------------------------------------------------
openmetadata-deps: namespaces
	# No --wait: the Airflow migration Job is a post-install hook and must run
	# before pods become ready. With --wait those pods would block hook execution.
	$(HELM) upgrade --install openmetadata-dependencies \
		open-metadata/openmetadata-dependencies \
		--namespace $(NAMESPACE) \
		--values openmetadata/dependencies-values.yaml \
		--timeout 5m

openmetadata: namespaces
	# mysql-secrets: MySQL password for OpenMetadata server
	$(KUBECTL) get secret mysql-secrets --namespace $(NAMESPACE) >/dev/null 2>&1 || \
	$(KUBECTL) create secret generic mysql-secrets \
		--namespace $(NAMESPACE) \
		--from-literal=openmetadata-mysql-password=openmetadata_password
	# airflow-secrets: Airflow admin password for OpenMetadata pipeline client
	$(KUBECTL) get secret airflow-secrets --namespace $(NAMESPACE) >/dev/null 2>&1 || \
	$(KUBECTL) create secret generic airflow-secrets \
		--namespace $(NAMESPACE) \
		--from-literal=openmetadata-airflow-password=admin
	$(HELM) upgrade --install openmetadata open-metadata/openmetadata \
		--namespace $(NAMESPACE) \
		--values openmetadata/values.yaml \
		--wait --timeout 10m

# ---------------------------------------------------------------------------
# Apache Superset — interactive data exploration UI
# Deploys into its own namespace (SUPERSET_NAMESPACE, default: superset) so its
# PostgreSQL and Redis sub-charts are isolated from the lakehouse services.
# The superset-secrets K8s secret is created here (not in `credentials`) because
# it belongs to SUPERSET_NAMESPACE, not the main lakehouse NAMESPACE.
# ---------------------------------------------------------------------------
superset:
	$(KUBECTL) create namespace $(SUPERSET_NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) create secret generic superset-secrets \
		--namespace $(SUPERSET_NAMESPACE) \
		--from-literal=SECRET_KEY=$(SUPERSET_SECRET_KEY) \
		--from-literal=DB_HOST=superset-postgresql \
		--from-literal=DB_PORT=5432 \
		--from-literal=DB_USER=superset \
		--from-literal=DB_NAME=superset \
		--from-literal=DB_PASS=$(SUPERSET_DB_PASSWORD) \
		--from-literal=postgresql-password=$(SUPERSET_DB_PASSWORD) \
		--from-literal=REDIS_HOST=superset-redis-headless \
		--from-literal=REDIS_PORT=6379 \
		--from-literal=REDIS_PROTO=redis \
		--from-literal=REDIS_CELERY_DB=0 \
		--from-literal=SUPERSET_ADMIN_PASSWORD=$(SUPERSET_ADMIN_PASSWORD) \
		--from-literal=TRINO_CLIENT_ID=PositionService \
		--from-literal=TRINO_CLIENT_SECRET=$(KEYCLOAK_POSITION_SECRET) \
		--from-literal=KEYCLOAK_URL=$(KEYCLOAK_URL) \
		--from-literal=KEYCLOAK_REALM=$(KEYCLOAK_REALM) \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(HELM) upgrade --install superset superset/superset \
		--namespace $(SUPERSET_NAMESPACE) \
		--version 0.16.2 \
		--values superset/values.yaml \
		--wait --timeout 10m

# ---------------------------------------------------------------------------
# Post-deploy helpers
# ---------------------------------------------------------------------------
init-storage:
	NAMESPACE=$(NAMESPACE) S3_SVC_NAME=$(S3_SVC_NAME) \
	S3_ACCESS_KEY=$(S3_ACCESS_KEY) S3_SECRET_KEY=$(S3_SECRET_KEY) \
	S3_BUCKET=$(or $(BUCKET),$(firstword $(CATALOGS))) \
		bash scripts/init-storage.sh

register-tables:
	NAMESPACE=$(NAMESPACE) bash scripts/register-existing-tables.sh

# ---------------------------------------------------------------------------
# Convenience targets
# ---------------------------------------------------------------------------
status:
	$(KUBECTL) get pods --namespace $(NAMESPACE)
	@echo ""
	$(HELM) list --namespace $(NAMESPACE)

pf-trino:
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/trino 8080:8080

pf-polaris:
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/polaris 8181:8181

pf-openmetadata:
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/openmetadata 8585:8585

pf-seaweedfs-s3:
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/$(S3_SVC_NAME) 8333:8333

pf-superset:
	$(KUBECTL) port-forward --namespace $(SUPERSET_NAMESPACE) svc/superset 8088:8088

# ---------------------------------------------------------------------------
# Teardown — removes all Helm releases, secrets, ConfigMap, and namespace
# ---------------------------------------------------------------------------
teardown:
	$(HELM) uninstall superset                   --namespace $(SUPERSET_NAMESPACE) --ignore-not-found
	$(KUBECTL) delete namespace $(SUPERSET_NAMESPACE) --ignore-not-found
	$(HELM) uninstall openmetadata               --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall openmetadata-dependencies  --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall trino                      --namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete configmap trino-access-control --namespace $(NAMESPACE) --ignore-not-found || true
	$(KUBECTL) delete secret trino-internal-shared-secret --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall polaris                    --namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete job polaris-db-init        --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall polaris-postgresql         --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall $(SEAWEEDFS_RELEASE)        --namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete secret \
		mysql-secrets airflow-secrets \
		seaweedfs-s3-credentials s3-credentials \
		polaris-bootstrap-credentials polaris-trino-credentials \
		polaris-jdbc-credentials \
		--namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete configmap lakehouse-config \
		--namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete namespace $(NAMESPACE) --ignore-not-found
