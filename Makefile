# Deploy the billing stack - SSO, billing, subscription and the internal
# billing gateway - and wire the external APISIX gateway to it.
#
#   make secrets      build the Secrets from the cluster + each repo's .env
#   make deploy       apply every manifest and wait for the rollouts
#   make routes       write the APISIX routes through the Admin API
#   make verify       smoke-test the public health route through APISIX
#
# Targets whatever cluster the current kubeconfig points at.

KUBECTL ?= kubectl
NAMESPACE ?= default
# subscription runs in its own namespace; everything else is in NAMESPACE.
SUBSCRIPTION_NAMESPACE ?= subscription

# APISIX here is the Helm release in the apisix namespace: the Admin API is a
# separate ClusterIP Service (apisix-admin), and the data plane is published
# as a NodePort because this cluster runs no ingress controller.
APISIX_NAMESPACE ?= apisix
APISIX_ADMIN_SVC ?= apisix-admin
APISIX_ADMIN_PORT ?= 9180
GATEWAY_URL ?= http://10.10.10.1:32756

# Read straight out of the running APISIX config rather than a checked-in
# value, so it follows the Helm release if the key is ever rotated.
APISIX_ADMIN_KEY ?= $(shell $(KUBECTL) -n $(APISIX_NAMESPACE) get cm apisix -o jsonpath='{.data.config\.yaml}' 2>/dev/null | python3 -c "import sys,yaml;d=yaml.safe_load(sys.stdin) or {};ks=((d.get('deployment') or {}).get('admin') or {}).get('admin_key') or [];print(next((k.get('key','') for k in ks if k.get('role')=='admin'),''))" 2>/dev/null)

SERVICES ?= sso billing subscription billing-getway-internal
SERVICE ?= billing-getway-internal

# Namespace lookup for a single service, used by the per-service targets.
ns_of = $(if $(filter subscription,$(1)),$(SUBSCRIPTION_NAMESPACE),$(NAMESPACE))

.PHONY: help secrets secrets-check deploy all undeploy restart status logs port-forward routes routes-delete verify \
        sso billing subscription gateway getway \
        restart-sso restart-billing restart-subscription restart-getway

help:
	@echo "secrets       build every Secret from the cluster + each repo's .env"
	@echo "secrets-check report what the secret build would do, change nothing"
	@echo "deploy        apply every manifest and wait for the rollouts"
	@echo "all           secrets + deploy + routes"
	@echo "undeploy      delete the workloads (routes and Secrets are left alone)"
	@echo "restart       roll one Deployment       (SERVICE=$(SERVICE))"
	@echo "logs          follow one Deployment     (SERVICE=$(SERVICE))"
	@echo "status        pods, services and endpoints for the whole stack"
	@echo "port-forward  expose the APISIX Admin API on 127.0.0.1:$(APISIX_ADMIN_PORT)"
	@echo "routes        seed the APISIX routes (auto port-forwards)"
	@echo "routes-delete remove the APISIX routes"
	@echo "verify        curl the public health route through APISIX"
	@echo ""
	@echo ""
	@echo "sso | billing | subscription | getway"
	@echo "              deploy one service on its own and wait for it"
	@echo "restart-sso | restart-billing | restart-subscription | restart-getway"
	@echo "              roll one service (needed after a ConfigMap-only change)"
	@echo ""
	@echo "services: $(SERVICES)"
	@echo "gateway : $(GATEWAY_URL)"
	@echo "namespaces: $(NAMESPACE), subscription=$(SUBSCRIPTION_NAMESPACE)"

secrets:
	./scripts/build-secrets.sh

secrets-check:
	./scripts/build-secrets.sh --check

# A completed Job is immutable, so re-applying the database bootstrap over a
# finished one fails on its generated selector - delete it first.
deploy:
	-$(KUBECTL) -n postgres delete job sso-db-init --ignore-not-found
	$(KUBECTL) apply -k .
	$(KUBECTL) -n postgres wait --for=condition=complete job/sso-db-init --timeout=180s
	@for s in $(SERVICES); do \
	  ns=$(NAMESPACE); [ "$$s" = "subscription" ] && ns=$(SUBSCRIPTION_NAMESPACE); \
	  $(KUBECTL) -n $$ns rollout status deployment/$$s --timeout=300s || exit 1; \
	done

# Deploy one service without touching the rest. Each applies just its own
# manifest, so a change to one service does not risk rolling the others.
sso:
	$(KUBECTL) apply -f sso.yml
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/sso --timeout=300s

billing:
	$(KUBECTL) apply -f billing.yml
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/billing --timeout=300s

# Creates the subscription namespace (declared in the manifest) and needs its
# Secrets to already exist there - `make secrets` puts them in both namespaces.
subscription:
	$(KUBECTL) apply -f subscription.yml
	$(KUBECTL) -n $(SUBSCRIPTION_NAMESPACE) rollout status deployment/subscription --timeout=300s

gateway:
	$(KUBECTL) apply -f billing-getway.yml
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/billing-getway-internal --timeout=300s

# The rest of this repo spells it "getway", so both work.
getway: gateway

all: secrets deploy routes

undeploy:
	$(KUBECTL) delete -k . --ignore-not-found

restart:
	$(KUBECTL) -n $(call ns_of,$(SERVICE)) rollout restart deployment/$(SERVICE)
	$(KUBECTL) -n $(call ns_of,$(SERVICE)) rollout status deployment/$(SERVICE) --timeout=300s

# Named shortcuts for the generic target above. Use one of these after editing
# a ConfigMap: `make <service>` only applies the manifest, and if the
# Deployment spec is unchanged Kubernetes creates no new revision, so the
# running pod keeps its old environment until it is rolled.
restart-sso:
	@$(MAKE) --no-print-directory restart SERVICE=sso

restart-billing:
	@$(MAKE) --no-print-directory restart SERVICE=billing

restart-subscription:
	@$(MAKE) --no-print-directory restart SERVICE=subscription

restart-getway:
	@$(MAKE) --no-print-directory restart SERVICE=billing-getway-internal

status:
	@for s in $(SERVICES); do \
	  ns=$(NAMESPACE); [ "$$s" = "subscription" ] && ns=$(SUBSCRIPTION_NAMESPACE); \
	  $(KUBECTL) -n $$ns get pods,svc -l app=$$s --no-headers 2>/dev/null; \
	done

logs:
	$(KUBECTL) -n $(call ns_of,$(SERVICE)) logs -f deployment/$(SERVICE)

port-forward:
	$(KUBECTL) -n $(APISIX_NAMESPACE) port-forward svc/$(APISIX_ADMIN_SVC) $(APISIX_ADMIN_PORT):9180

routes:
	@$(MAKE) --no-print-directory _with-admin-api ARGS=""

routes-delete:
	@$(MAKE) --no-print-directory _with-admin-api ARGS="--delete"

.PHONY: _with-admin-api
_with-admin-api:
	@test -n "$(APISIX_ADMIN_KEY)" || { echo "APISIX_ADMIN_KEY is empty - could not read it from the apisix ConfigMap"; exit 1; }
	@set -e; \
	if [ -n "$(APISIX_ADMIN_URL)" ]; then \
	  APISIX_ADMIN_KEY="$(APISIX_ADMIN_KEY)" APISIX_ADMIN_URL="$(APISIX_ADMIN_URL)" ./apisix/seed-routes.sh $(ARGS); \
	else \
	  $(KUBECTL) -n $(APISIX_NAMESPACE) port-forward svc/$(APISIX_ADMIN_SVC) $(APISIX_ADMIN_PORT):9180 >/dev/null 2>&1 & \
	  pf=$$!; \
	  trap "kill $$pf 2>/dev/null || true" EXIT; \
	  for i in $$(seq 1 30); do \
	    curl -sS -o /dev/null "http://127.0.0.1:$(APISIX_ADMIN_PORT)/apisix/admin/routes" -H "X-API-KEY: $(APISIX_ADMIN_KEY)" && break; \
	    sleep 1; \
	  done; \
	  APISIX_ADMIN_KEY="$(APISIX_ADMIN_KEY)" APISIX_ADMIN_URL="http://127.0.0.1:$(APISIX_ADMIN_PORT)" ./apisix/seed-routes.sh $(ARGS); \
	fi

# /mobile/v1/health is the one route the gateway exempts from token
# verification, so a 200 here proves the whole path: APISIX -> route ->
# upstream -> grpc-gateway -> gRPC handler.
verify:
	curl -fsS "$(GATEWAY_URL)/mobile/v1/health" && echo
