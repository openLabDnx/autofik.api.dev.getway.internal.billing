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

.PHONY: help namespace secret fix-secret deploy all undeploy restart status logs port-forward routes routes-delete routes-dashboard verify tf-init tf-plan tf-apply tf-show tf-state-namespace ansible-deploy ansible-local ansible-ping

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
	@echo ""
	@echo "Terraform (per environment - ENV=dev|stg|prod, KUBECONFIG picks the cluster):"
	@echo "tf-init       terraform init for ENV (state is a Secret in that cluster)"
	@echo "tf-plan       show what deploying IMAGE_TAG=<tag> to ENV would change"
	@echo "tf-apply      point ENV's ArgoCD Application at IMAGE_TAG=<tag>"
	@echo "tf-show       what is currently pinned in ENV"
	@echo ""
	@echo "  make tf-init ENV=prod && make tf-apply ENV=prod IMAGE_TAG=prod-1.2.3"
	@echo ""
	@echo "Ansible (the whole CI deploy in one command - ENV comes from the tag):"
	@echo "ansible-deploy  init + apply + wait for ArgoCD, IMAGE_TAG=<tag> [YES=1]"
	@echo "ansible-local   kubectl-only deploy to the local cluster, [IMAGE_TAG=<tag>]"
	@echo "ansible-ping    check SSH + sudo to the cluster nodes in ansible/inventory.yml"

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

# ---------------------------------------------------------------------------
# Terraform - the release-triggered deploy, per environment
#
# Terraform owns ONLY the ArgoCD Application, whose kustomize overrides pin
# which image tag ArgoCD rolls out and how many replicas it runs. It does not
# manage the Deployment; the Application's selfHeal would just revert it.
#
# dev, stg and prod are three separate clusters, each with its own ArgoCD and
# its own Terraform state. Every target below therefore needs BOTH:
#
#   ENV=<dev|stg|prod>   picks the state Secret and the release channel
#   KUBECONFIG=<path>    picks the cluster
#
# Get those two out of step and you would deploy to the wrong cluster, so
# `tf-apply` prints the context it is about to write to and, for prod, asks
# first. Normally CI does all of this on a repository_dispatch from the app
# repo - these targets are for doing it by hand (a rollback, or the first run).
#
#   make tf-init  ENV=prod
#   make tf-plan  ENV=prod IMAGE_TAG=prod-1.2.3
#   make tf-apply ENV=prod IMAGE_TAG=prod-1.2.3
# ---------------------------------------------------------------------------

TF ?= terraform
TF_DIR ?= terraform
KUBECONFIG_PATH ?= $(if $(KUBECONFIG),$(KUBECONFIG),$(HOME)/.kube/config)
TF_STATE_NAMESPACE ?= terraform-state

# Every tf-* target funnels through this, so a typo in ENV can never reach a
# cluster. The tfvars file has to exist too - that is what makes `ENV=prod`
# mean "the settings in envs/prod.tfvars" rather than just a string.
define require_env
@test -n "$(ENV)" || { echo "ENV is required: make $@ ENV=dev|stg|prod"; exit 1; }
@test -f "$(TF_DIR)/envs/$(ENV).tfvars" || { echo "unknown ENV '$(ENV)' - no $(TF_DIR)/envs/$(ENV).tfvars (expected dev, stg or prod)"; exit 1; }
endef

# One state Secret per environment. This suffix is the ONLY thing keeping the
# three states apart, so it is derived from ENV and never typed by hand.
TF_STATE_SUFFIX = billing-getway-$(ENV)

TF_VARS = -var-file="envs/$(ENV).tfvars" -var="kubeconfig_path=$(KUBECONFIG_PATH)"

# The kubernetes backend stores a Secret but will not create its namespace.
tf-state-namespace:
	$(KUBECTL) --kubeconfig="$(KUBECONFIG_PATH)" create namespace $(TF_STATE_NAMESPACE) --dry-run=client -o yaml \
	  | $(KUBECTL) --kubeconfig="$(KUBECONFIG_PATH)" apply -f -

# -reconfigure, not -migrate-state: switching ENV points at a DIFFERENT state
# that already exists. Without it Terraform offers to copy dev's state over
# prod's, which is exactly the accident this layout exists to prevent.
tf-init:
	$(require_env)
	@$(MAKE) --no-print-directory tf-state-namespace ENV=$(ENV)
	cd $(TF_DIR) && $(TF) init -input=false -reconfigure \
	  -backend-config="config_path=$(KUBECONFIG_PATH)" \
	  -backend-config="secret_suffix=$(TF_STATE_SUFFIX)"

tf-plan:
	$(require_env)
	@test -n "$(IMAGE_TAG)" || { echo "IMAGE_TAG is required, e.g. make tf-plan ENV=$(ENV) IMAGE_TAG=$(ENV)-1.2.3"; exit 1; }
	cd $(TF_DIR) && $(TF) plan -input=false $(TF_VARS) -var="image_tag=$(IMAGE_TAG)"

# Prints the cluster before it writes anything, because ENV and KUBECONFIG are
# set independently and nothing else would catch a mismatch. Pass YES=1 to
# skip the prompt (CI does).
tf-apply:
	$(require_env)
	@test -n "$(IMAGE_TAG)" || { echo "IMAGE_TAG is required, e.g. make tf-apply ENV=$(ENV) IMAGE_TAG=$(ENV)-1.2.3"; exit 1; }
	@echo "environment : $(ENV)"
	@echo "image tag   : $(IMAGE_TAG)"
	@echo "state secret: tfstate-default-$(TF_STATE_SUFFIX) (ns $(TF_STATE_NAMESPACE))"
	@echo "kubeconfig  : $(KUBECONFIG_PATH)"
	@echo "context     : $$($(KUBECTL) --kubeconfig="$(KUBECONFIG_PATH)" config current-context 2>/dev/null || echo '<none>')"
	@echo "cluster     : $$($(KUBECTL) --kubeconfig="$(KUBECONFIG_PATH)" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo '<none>')"
	@test -n "$(YES)" || { \
	  printf 'Deploy %s to %s? [y/N] ' "$(IMAGE_TAG)" "$(ENV)"; \
	  read ans; [ "$$ans" = y ] || [ "$$ans" = Y ] || { echo aborted; exit 1; }; \
	}
	cd $(TF_DIR) && $(TF) apply -input=false -auto-approve $(TF_VARS) -var="image_tag=$(IMAGE_TAG)"

# What is live in one environment, straight from its state.
tf-show:
	$(require_env)
	cd $(TF_DIR) && $(TF) output

# ---------------------------------------------------------------------------
# Ansible - the same deploy as .github/workflows/deploy.yml, run from here
#
# One command instead of tf-init + tf-apply + watching ArgoCD by hand. There is
# no ENV: like CI, the playbook derives it from IMAGE_TAG's channel prefix and
# picks that environment's kubeconfig from ansible/envs/<env>.yml
# ($KUBECONFIG_<ENV>, then $KUBECONFIG). prod asks first; YES=1 skips that.
#
#   make ansible-deploy IMAGE_TAG=prod-1.2.3
# ---------------------------------------------------------------------------

ANSIBLE_PLAYBOOK ?= ansible-playbook

# `cd ansible` so its ansible.cfg and inventory are picked up.
ansible-deploy:
	@test -n "$(IMAGE_TAG)" || { echo "IMAGE_TAG is required, e.g. make ansible-deploy IMAGE_TAG=dev-1.2.3"; exit 1; }
	cd ansible && $(ANSIBLE_PLAYBOOK) deploy.yml -e image_tag="$(IMAGE_TAG)" \
	  $(if $(YES),-e auto_approve=true) $(ANSIBLE_ARGS)

# Local cluster only (kubectl, no Terraform/ArgoCD). IMAGE_TAG is optional.
#
#   make ansible-local
#   make ansible-local IMAGE_TAG=dev-1.2.3
ansible-local:
	cd ansible && $(ANSIBLE_PLAYBOOK) local.yml $(if $(IMAGE_TAG),-e image_tag="$(IMAGE_TAG)") $(ANSIBLE_ARGS)

# dev deploys run ON the nprd RKE2 node over SSH (ansible/host_vars/nprd-rke2/),
# so check that login and sudo work before the first deploy.
ansible-ping:
	cd ansible && ansible dev -m ansible.builtin.command -a "id -un" --become $(ANSIBLE_ARGS)
