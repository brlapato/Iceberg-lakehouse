ENV ?= lakehouse

# Load environment-specific settings (namespace, credentials, etc.)
include env/$(ENV).mk

HELM    := helm
KUBECTL := kubectl

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

.PHONY: all repos namespaces credentials config seaweedfs polaris trino \
        openmetadata-deps openmetadata init-storage register-tables \
        status teardown \
        pf-trino pf-polaris pf-openmetadata pf-seaweedfs-s3

# Deploy everything in dependency order
all: repos namespaces credentials config seaweedfs polaris trino openmetadata-deps openmetadata

# ---------------------------------------------------------------------------
# Helm repository setup
# ---------------------------------------------------------------------------
repos:
	$(HELM) repo add seaweedfs      https://seaweedfs.github.io/seaweedfs/helm
	$(HELM) repo add polaris        https://downloads.apache.org/polaris/helm-chart
	$(HELM) repo add trino          https://trinodb.github.io/charts
	$(HELM) repo add open-metadata  https://helm.open-metadata.org
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

config: namespaces
	# Service endpoints and bucket name — consumed by Polaris and Trino via configMapKeyRef
	$(KUBECTL) create configmap lakehouse-config \
		--namespace $(NAMESPACE) \
		--from-literal=s3-endpoint=$(S3_ENDPOINT) \
		--from-literal=polaris-catalog-uri=$(POLARIS_CATALOG_URI) \
		--from-literal=s3-bucket=$(S3_BUCKET) \
		--dry-run=client -o yaml | $(KUBECTL) apply -f -

# ---------------------------------------------------------------------------
# SeaweedFS — object storage (S3-compatible)
# ---------------------------------------------------------------------------
seaweedfs: namespaces credentials
	$(HELM) upgrade --install $(SEAWEEDFS_RELEASE) seaweedfs/seaweedfs \
		--namespace $(NAMESPACE) \
		--values seaweedfs/values.yaml \
		--set s3.domainName=$(S3_HOST) \
		--set 's3.createBuckets[0].name=$(S3_BUCKET)' \
		--wait --timeout 5m

# ---------------------------------------------------------------------------
# Apache Polaris — Iceberg REST Catalog (v1.5.0)
# Deploys Polaris then runs init-polaris.sh to bootstrap the warehouse
# catalog, create the trino service principal, and write the
# polaris-trino-credentials K8s secret that Trino reads at startup.
# ---------------------------------------------------------------------------
polaris: namespaces credentials config
	$(HELM) upgrade --install polaris polaris/polaris \
		--namespace $(NAMESPACE) \
		--version 1.5.0 \
		--values polaris/values.yaml \
		--wait --timeout 5m
	NAMESPACE=$(NAMESPACE) S3_SVC_NAME=$(S3_SVC_NAME) bash scripts/patch-polaris-hosts.sh
	NAMESPACE=$(NAMESPACE) \
	POLARIS_ROOT_ID=$(POLARIS_ROOT_ID) \
	POLARIS_ROOT_SECRET=$(POLARIS_ROOT_SECRET) \
	S3_BUCKET=$(S3_BUCKET) \
	S3_ENDPOINT=$(S3_ENDPOINT) \
		bash scripts/init-polaris.sh

# ---------------------------------------------------------------------------
# Trino — distributed SQL query engine
# Must run after 'polaris' so the polaris-trino-credentials secret exists.
# ---------------------------------------------------------------------------
trino: namespaces credentials config
	$(HELM) upgrade --install trino trino/trino \
		--namespace $(NAMESPACE) \
		--values trino/values.yaml \
		--wait --timeout 5m

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
# Post-deploy: create the S3_BUCKET bucket in SeaweedFS (if not using createBuckets)
# ---------------------------------------------------------------------------
init-storage:
	NAMESPACE=$(NAMESPACE) \
	S3_SVC_NAME=$(S3_SVC_NAME) \
	S3_ACCESS_KEY=$(S3_ACCESS_KEY) \
	S3_SECRET_KEY=$(S3_SECRET_KEY) \
	S3_BUCKET=$(S3_BUCKET) \
		bash scripts/init-storage.sh

# ---------------------------------------------------------------------------
# Post-deploy: register pre-existing Iceberg tables from SeaweedFS into Polaris.
# Run this after switching from Nessie if you want to preserve existing data.
# ---------------------------------------------------------------------------
register-tables:
	NAMESPACE=$(NAMESPACE) bash scripts/register-existing-tables.sh

# ---------------------------------------------------------------------------
# Convenience targets
# ---------------------------------------------------------------------------
status:
	$(KUBECTL) get pods --namespace $(NAMESPACE)
	@echo ""
	$(HELM) list --namespace $(NAMESPACE)

# Port-forward shortcuts (run each in a separate terminal)
pf-trino:
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/trino 8080:8080

pf-polaris:
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/polaris 8181:8181

pf-openmetadata:
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/openmetadata 8585:8585

pf-seaweedfs-s3:
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/$(S3_SVC_NAME) 8333:8333

# ---------------------------------------------------------------------------
# Teardown — removes all Helm releases, secrets, ConfigMap, and namespace
# ---------------------------------------------------------------------------
teardown:
	$(HELM) uninstall openmetadata               --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall openmetadata-dependencies  --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall trino                      --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall polaris                    --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall $(SEAWEEDFS_RELEASE)        --namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete secret \
		mysql-secrets airflow-secrets \
		seaweedfs-s3-credentials s3-credentials \
		polaris-bootstrap-credentials polaris-trino-credentials \
		--namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete configmap lakehouse-config \
		--namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete namespace $(NAMESPACE) --ignore-not-found
