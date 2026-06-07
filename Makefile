NAMESPACE := lakehouse
HELM      := helm
KUBECTL   := kubectl

.PHONY: all repos namespaces config seaweedfs polaris trino \
        openmetadata-deps openmetadata \
        tls keycloak-config keycloak-secrets \
        ranger-image ranger \
        init-storage register-tables \
        status teardown \
        pf-trino pf-polaris pf-openmetadata pf-seaweedfs-s3 pf-ranger

# ---------------------------------------------------------------------------
# Deploy everything in dependency order.
#
# Prerequisites (run once before 'make all'):
#   make keycloak-config  — render config/lakehouse-config.yaml into values files
#   make tls              — generate TLS cert + K8s secrets for Trino
#   make keycloak-secrets — create K8s secrets from Keycloak client secrets
#   make ranger-image     — build Ranger Docker image into minikube
# ---------------------------------------------------------------------------
all: repos namespaces config seaweedfs polaris openmetadata-deps ranger trino openmetadata

# ---------------------------------------------------------------------------
# Central config — apply the lakehouse ConfigMap to the cluster.
# Edit config/lakehouse-config.yaml then run 'make config'.
# After changing Keycloak URL/realm or Ranger URL, run 'make keycloak-config'
# first — it recomputes derived fields and patches component values files.
# ---------------------------------------------------------------------------
config: namespaces
	$(KUBECTL) apply -f config/lakehouse-config.yaml

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
# Apache Polaris — Iceberg REST Catalog (v1.5.0)
# Deploys Polaris then runs init-polaris.sh to bootstrap the warehouse
# catalog, create the trino service principal, and write the
# polaris-trino-credentials K8s secret that Trino reads at startup.
# ---------------------------------------------------------------------------
polaris: namespaces
	$(HELM) upgrade --install polaris polaris/polaris \
		--namespace $(NAMESPACE) \
		--version 1.5.0 \
		--values polaris/values.yaml \
		--wait --timeout 5m
	NAMESPACE=$(NAMESPACE) bash scripts/patch-polaris-hosts.sh
	NAMESPACE=$(NAMESPACE) bash scripts/init-polaris.sh

# ---------------------------------------------------------------------------
# TLS — generate self-signed certificate for Trino HTTPS
# Creates K8s secrets: trino-tls, trino-internal-secret
# Run once before 'make trino' (or re-run to rotate the certificate).
# ---------------------------------------------------------------------------
tls: namespaces
	NAMESPACE=$(NAMESPACE) bash scripts/generate-tls.sh

# ---------------------------------------------------------------------------
# Render config — propagate config/lakehouse-config.yaml into component
# values files that cannot consume it via envFrom at runtime.
# Patches: openmetadata/values.yaml (OIDC authority + JWKS URL)
#          trino/values.yaml (Ranger XML policy URL + service name)
#          ranger/values.yaml (policymgrUrl)
#          config/lakehouse-config.yaml (derived KEYCLOAK_ISSUER_URL + KEYCLOAK_JWKS_URL)
# Run after editing config/lakehouse-config.yaml, then 'make config'.
# ---------------------------------------------------------------------------
keycloak-config:
	python3 scripts/render-values.py
	$(MAKE) config

# ---------------------------------------------------------------------------
# Keycloak secrets — create K8s secrets from Keycloak client credentials
# Interactive: prompts for client secrets for Trino and OpenMetadata.
# Creates K8s secrets: keycloak-trino, keycloak-openmetadata
# ---------------------------------------------------------------------------
keycloak-secrets: namespaces
	NAMESPACE=$(NAMESPACE) bash scripts/keycloak-secrets.sh

# ---------------------------------------------------------------------------
# Trino — distributed SQL query engine
# Must run after 'polaris' (polaris-trino-credentials secret),
# 'tls' (trino-tls + trino-internal-secret secrets), and
# 'keycloak-secrets' (keycloak-trino secret).
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
# Apache Ranger Admin — policy management for Trino RBAC
#
# Prerequisites:
#   make ranger-image       — build the Ranger Docker image into minikube
#   make openmetadata-deps  — MySQL must be running (Ranger shares it)
# ---------------------------------------------------------------------------

# Build Ranger Admin Docker image into minikube's local registry.
# Run once, or again to upgrade the Ranger version.
ranger-image:
	eval $$(minikube docker-env) && \
	docker build -t ranger-admin:2.6.0 ranger/

# Deploy Ranger Admin and bootstrap it with the Trino service definition.
ranger: namespaces
	$(HELM) upgrade --install ranger ./ranger/chart \
		--namespace $(NAMESPACE) \
		--values ranger/values.yaml \
		--wait --timeout 10m
	NAMESPACE=$(NAMESPACE) bash scripts/init-ranger.sh

# ---------------------------------------------------------------------------
# Post-deploy: create the 'warehouse' bucket in SeaweedFS
# ---------------------------------------------------------------------------
init-storage:
	NAMESPACE=$(NAMESPACE) bash scripts/init-storage.sh

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
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/trino 8443:8443

pf-polaris:
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/polaris 8181:8181

pf-openmetadata:
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/openmetadata 8585:8585

pf-seaweedfs-s3:
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/seaweedfs-filer 8333:8333

pf-ranger:
	$(KUBECTL) port-forward --namespace $(NAMESPACE) svc/ranger 6080:6080

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
teardown:
	$(HELM) uninstall ranger                     --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall openmetadata               --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall openmetadata-dependencies  --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall trino                      --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall polaris                    --namespace $(NAMESPACE) --ignore-not-found
	$(HELM) uninstall seaweedfs                  --namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete secret mysql-secrets airflow-secrets \
		--namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete secret seaweedfs-s3-credentials \
		--namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete secret polaris-trino-credentials \
		--namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete secret keycloak-trino keycloak-openmetadata \
		--namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete secret trino-tls trino-internal-secret \
		--namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete configmap lakehouse-config \
		--namespace $(NAMESPACE) --ignore-not-found
	$(KUBECTL) delete -f namespaces.yaml --ignore-not-found
