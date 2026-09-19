# Deploy the internal billing gateway and wire the external APISIX gateway to it.
#
#   make deploy       apply the Kubernetes manifests
#   make routes       write the APISIX routes through the Admin API
#   make verify       smoke-test the public health route through APISIX
#
# Everything targets whatever cluster your current kubeconfig points at; set
# KUBECONFIG (on the RKE2 host: /etc/rancher/rke2/rke2.yaml) to pick another.

KUBECTL ?= kubectl
NAMESPACE ?= billing-gateway
APISIX_NAMESPACE ?= apisix
APISIX_ADMIN_PORT ?= 9180
APISIX_HOSTNAME ?= apisix.master.autofik.com

# The published APISIX dashboard, used by `routes-dashboard`. The dashboard
# login is `admin` - not `apisix`, which is only the Kubernetes namespace.
DASH_URL ?= https://apisix.master.autofik.com
DASH_USER ?= admin

# The ansible run that provisioned APISIX persisted the Admin API key here.
# Override APISIX_ADMIN_KEY on the command line when running from elsewhere.
APISIX_ADMIN_KEY_FILE ?= ../../api/ansible/.secrets/apisix_admin_key
APISIX_ADMIN_KEY ?= $(shell [ -f "$(APISIX_ADMIN_KEY_FILE)" ] && tr -d "[:space:]" < "$(APISIX_ADMIN_KEY_FILE)")

.PHONY: help namespace secret fix-secret deploy all undeploy restart status logs port-forward routes routes-delete routes-dashboard verify

help:
	@echo "namespace     create the $(NAMESPACE) namespace (idempotent)"
	@echo "secret        apply secret.yml (copy it from secret.example.yml first)"
	@echo "fix-secret    namespace + secret + unstick CreateContainerConfigError pods"
	@echo "deploy        apply the ConfigMap/Deployment/Service"
	@echo "all           secret + deploy + routes"
	@echo "undeploy      delete the workload (routes and Secret are left alone)"
	@echo "restart       roll the Deployment (picks up a new :master image)"
	@echo "status        pods, service and endpoints"
	@echo "logs          follow the gateway logs"
	@echo "port-forward  expose the APISIX Admin API on 127.0.0.1:$(APISIX_ADMIN_PORT)"
	@echo "routes        seed the APISIX routes (auto port-forwards)"
	@echo "routes-delete remove the APISIX routes"
	@echo "routes-dashboard  seed the routes through the published dashboard (no kubeconfig needed)"
	@echo "verify        curl the public health route through APISIX"

# The Deployment consumes this Secret via envFrom, so it must exist before
# the pod can start - apply it first, not after. The namespace has to exist
# before anything can go into it, so ensure it here as well (idempotent).
secret: namespace
	@test -f secret.yml || { echo "secret.yml not found - cp secret.example.yml secret.yml and fill it in"; exit 1; }
	$(KUBECTL) apply -f secret.yml

namespace:
	$(KUBECTL) create namespace $(NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f -

# One-shot repair for a pod stuck in CreateContainerConfigError: ensures the
# namespace, applies the Secret, deletes the wedged pods and waits. Prompts
# for confirmation and prints the target cluster first - pass YES=1 to skip.
# Point it at another cluster with KUBECONFIG=... or CONTEXT=...
fix-secret:
	NAMESPACE=$(NAMESPACE) ./scripts/fix-secret.sh

deploy:
	$(KUBECTL) apply -k .
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/billing-getway-internal --timeout=180s

all: secret deploy routes

undeploy:
	$(KUBECTL) delete -k . --ignore-not-found

restart:
	$(KUBECTL) -n $(NAMESPACE) rollout restart deployment/billing-getway-internal
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/billing-getway-internal --timeout=180s

status:
	$(KUBECTL) -n $(NAMESPACE) get pods,svc,endpoints -l app=billing-getway-internal

logs:
	$(KUBECTL) -n $(NAMESPACE) logs -f deployment/billing-getway-internal

port-forward:
	$(KUBECTL) -n $(APISIX_NAMESPACE) port-forward svc/apisix-admin $(APISIX_ADMIN_PORT):9180

# The Admin API is ClusterIP-only, so this opens its own port-forward, seeds,
# and tears it down again. Pass APISIX_ADMIN_URL to skip that and talk to an
# already-reachable Admin API (e.g. a local docker APISIX).
routes:
	@$(MAKE) --no-print-directory _with-admin-api ARGS=""

routes-delete:
	@$(MAKE) --no-print-directory _with-admin-api ARGS="--delete"

.PHONY: _with-admin-api
_with-admin-api:
	@test -n "$(APISIX_ADMIN_KEY)" || { echo "APISIX_ADMIN_KEY is empty (looked in $(APISIX_ADMIN_KEY_FILE))"; exit 1; }
	@set -e; \
	if [ -n "$(APISIX_ADMIN_URL)" ]; then \
	  APISIX_ADMIN_KEY="$(APISIX_ADMIN_KEY)" APISIX_ADMIN_URL="$(APISIX_ADMIN_URL)" ./apisix/seed-routes.sh $(ARGS); \
	else \
	  $(KUBECTL) -n $(APISIX_NAMESPACE) port-forward svc/apisix-admin $(APISIX_ADMIN_PORT):9180 >/dev/null 2>&1 & \
	  pf=$$!; \
	  trap "kill $$pf 2>/dev/null || true" EXIT; \
	  for i in $$(seq 1 30); do \
	    curl -sS -o /dev/null "http://127.0.0.1:$(APISIX_ADMIN_PORT)/apisix/admin/routes" -H "X-API-KEY: $(APISIX_ADMIN_KEY)" && break; \
	    sleep 1; \
	  done; \
	  APISIX_ADMIN_KEY="$(APISIX_ADMIN_KEY)" APISIX_ADMIN_URL="http://127.0.0.1:$(APISIX_ADMIN_PORT)" ./apisix/seed-routes.sh $(ARGS); \
	fi

# Seed through the published dashboard instead of the Admin API. Use this for
# a cluster you have no kubeconfig for - the Admin API is ClusterIP-only with
# allow_admin 127.0.0.1/24, so there is no port-forward to open, but the
# dashboard is on HTTPS and writes to the same etcd.
#
#   make routes-dashboard DASH_PASS=<password>
routes-dashboard:
	@test -n "$(DASH_PASS)" || { echo "DASH_PASS is required (dashboard password for $(DASH_USER)@$(DASH_URL))"; exit 1; }
	DASH_URL="$(DASH_URL)" DASH_USER="$(DASH_USER)" DASH_PASS="$(DASH_PASS)" \
	  ADMIN_ALLOW_CIDRS="$(ADMIN_ALLOW_CIDRS)" ./apisix/seed-routes-dashboard.sh $(ARGS)

# /mobile/v1/health is the one route the gateway exempts from token
# verification, so a 200 here proves the whole path works: APISIX -> route ->
# upstream -> grpc-gateway -> gRPC handler.
verify:
	curl -fsS "https://$(APISIX_HOSTNAME)/mobile/v1/health" && echo
