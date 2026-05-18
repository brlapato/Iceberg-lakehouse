NAMESPACE := lakehouse
HELM      := helm
KUBECTL   := kubectl

.PHONY: all repos namespaces seaweedfs nessie trino \
        openmetadata-deps openmetadata init-storage \
        status teardown

# Deploy everything in dependency order
all: repos namespaces seaweedfs nessie trino openmetadata-deps openmetadata

# ---------------------------------------------------------------------------
# Helm repository setup
# ---------------------------------------------------------------------------
repos:
	$(HELM) repo add seaweedfs      https://seaweedfs.github.io/seaweedfs/helm
	$(HELM) repo add nessie         https://charts.projectnessie.org
	$(HELM) repo add trino          https://trinodb.github.io/charts
	$(HELM) repo add open-metadata  https://helm.open-metadata.org
	$(HELM) repo update

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
namespaces:
	$(KUBECTL) apply -f namespaces.yaml

# ---------------------------------------------------------------------------
# SeaweedFS — object storage (S3-compatible)
# ---------------------------------------------------------------------------
seaweedfs: namespaces
	$(KUBECTL) apply -f seaweedfs/s3-credentials.yaml
	$(HELM) upgrade --install seaweedfs seaweedfs/seaweedfs \
		--namespace $(NAMESPACE) \
		--values seaweedfs/values.yaml \
		--wait --timeout 5m

# ---------------------------------------------------------------------------
# Project Nessie — Iceberg catalog with Git-like versioning
# ---------------------------------------------------------------------------
nessie: namespaces
	$(KUBECTL) apply -f nessie/s3-credentials.yaml
	$(HELM) upgrade --install nessie nessie/nessie \
		--namespace $(NAMESPACE) \
		--values nessie/values.yaml \
		--wait --timeout 5m

# ---------------------------------------------------------------------------
# Trino — distributed SQL query engine
# ---------------------------------------------------------------------------
trino: namespaces
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
# Post-deploy: create the 'warehouse' bucket in SeaweedFS
# ---------------------------------------------------------------------------
init-storage:
	NAMESPACE=$(NAMESPACE) bash scripts/init-storage.sh

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

pf-nessie:
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/nessie 19120:19120

pf-openmetadata:
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/openmetadata 8585:8585

pf-seaweedfs-s3:
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/seaweedfs-filer 8333:8333

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
teardown:
	$(HELM) uninstall openmetadata               --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall openmetadata-dependencies  --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall trino                      --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall nessie                     --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall seaweedfs                  --namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete secret mysql-secrets airflow-secrets \
		--namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete secret seaweedfs-s3-credentials \
		--namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete secret nessie-s3-credentials \
		--namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete -f namespaces.yaml --ignore-not-found
