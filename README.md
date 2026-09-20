# billing-getway deploy

Deployment for **autofik.dev.api.billing.getway.internal** on the RKE2 cluster
from `api/ansible`, plus the APISIX configuration that puts it behind the
external gateway.

```
                                       ┌─ billing        :4041  (REST)
 mobile ──► APISIX ──► billing-getway ─┼─ subscription   :4040  (REST)
  app      (edge)      internal :8081  └─ user.auth.sso  :4000  (verify-token)
                              :50055 ◄── other in-cluster services (gRPC)
```

APISIX is the only way in from outside. It does no authentication of its own
here — it forwards `Authorization` untouched, and the gateway's
`UserVerificationUnaryInterceptor` verifies the bearer token against
user.auth.sso before any handler runs. There is no `grpc-transcode` plugin
either: the gateway binary transcodes REST ⇄ gRPC itself with grpc-gateway,
generated from the `google.api.http` options in `billing.proto`.

## Files

| File | What it is |
| --- | --- |
| `billing-getway.yml` | Namespace + ConfigMap + Deployment + Service for the gateway |
| `secret.example.yml` | template for the two downstream API keys |
| `kustomization.yaml` | what `kubectl apply -k .` applies |
| `apisix/seed-routes.sh` | writes the upstream + routes through the APISIX Admin API |
| `apisix/seed-routes-dashboard.sh` | the same objects through the published dashboard, for a cluster you have no kubeconfig for |
| `argocd-application.yaml` | the ArgoCD Application (bootstrap; Terraform owns it afterwards) |
| `terraform/` | pins which released image tag and replica count ArgoCD deploys, per environment - see [Releasing](#releasing-tag-build-deploy) |
| `terraform/envs/` | the dev / stg / prod settings, one `.tfvars` each |
| `.github/workflows/deploy.yml` | runs that Terraform when the app repo publishes a release |
| `Makefile` | the commands below |

## Deploy

```bash
export KUBECONFIG=/path/to/rke2.yaml     # on the RKE2 host: /etc/rancher/rke2/rke2.yaml

cp secret.example.yml secret.yml         # fill in both keys - see below
make secret                              # creates the namespace, then the Secret
make deploy                              # Namespace + ConfigMap + Deployment + Service
make routes                              # APISIX upstream + routes
make verify                              # 200 from /mobile/v1/health through APISIX
```

`make all` runs secret → deploy → routes in one go.

### Before the first deploy, check these three things

1. **Downstream URLs.** The `ConfigMap` in `billing-getway.yml` points at
   `billing.default.svc.cluster.local:4041`,
   `subscription.subscription.svc.cluster.local:4040` and
   `sso.default.svc.cluster.local:4000`. These are *other* namespaces on
   purpose - only the gateway's own objects live in `billing-gateway`.
   Those Services have no
   manifests in this repo yet, so the names are a guess — set them to whatever
   the Services are actually called, or to an external URL for anything still
   running outside the cluster. Nothing works until `USER_SERVICE_URL` is
   right: every request is authenticated against it.

2. **The two API keys** in `secret.yml`. Both downstream services gate their
   routes on an `x-publishable-api-key` header:
   `USER_SERVICE_PUBLISHABLE_API_KEY` (missing → user.auth.sso 401s, so every
   request looks like a bad token) and
   `SUBSCRIPTION_SERVICE_PUBLISHABLE_API_KEY` (missing → plan/subscription
   calls 400). The Deployment pulls the Secret in with `envFrom`, so the pod
   will not start at all until it exists.

3. **The image tag.** `autofikbyslaap/dev.api.billing.getway:master` is the
   moving dev tag the repo's `master.yml` workflow re-points on every `dev-v*`
   release. Pin `:dev-<version>` for a reproducible rollout. Under ArgoCD you
   never edit this line — Terraform overrides it per environment, see
   [Releasing](#releasing-tag-build-deploy).

## APISIX routes

> **ArgoCD does not create these routes.** The Application syncs
> `kustomization.yaml`, which contains only the ConfigMap, Deployment and
> Service. The routes are etcd entries written by a shell script, so a green
> ArgoCD sync tells you nothing about whether the gateway is reachable — an
> APISIX dashboard with no `billing-getway-*` routes is the expected state
> until you seed them by hand. Seed **after** the Application has synced.

`apisix/seed-routes.sh` writes three objects through the Admin API. APISIX
runs in `traditional` role with etcd as its config provider, so routes are
etcd entries, not Kubernetes objects — there is no CRD to `kubectl apply`.
The Admin API is ClusterIP-only on port 9180; `make routes` opens its own
`kubectl port-forward` and closes it again, and reads the admin key from
`api/ansible/.secrets/apisix_admin_key`.

| Object | Matches | Notes |
| --- | --- | --- |
| upstream `billing-getway-internal` | — | `billing-getway-internal.billing-gateway.svc.cluster.local:8081`, 30s read timeout |
| route `billing-getway-mobile` | `/mobile/v1/*` | the public surface, `cors` enabled |
| route `billing-getway-admin` | `/mobile/v1/admin/*`, `/mobile/v1/billings/approve`, `/mobile/v1/billings/reject` | priority 10, optional `ip-restriction` |

Paths are forwarded unchanged — the gateway already serves `/mobile/v1/...`
exactly as `billing.proto` declares it, so there is no `proxy-rewrite`.

`/internal/v1/token/verify` is **not** routed. It is for in-cluster callers
(e.g. the subscription service resolving a caller's identity); they reach it
on the ClusterIP Service directly, never through the edge.

### Seeding a cluster you have no kubeconfig for

`make routes` needs a port-forward, and the Admin API's `allow_admin` is
`127.0.0.1/24`, so without cluster credentials there is nothing to forward.
The dashboard is published over HTTPS, speaks the same `/apisix/admin/*`
paths and writes to the same etcd — it just authenticates with a JWT:

```bash
make routes-dashboard DASH_PASS=<dashboard password>

# other cluster, or removal
make routes-dashboard DASH_URL=https://apisix.testing.autofik.com DASH_PASS=...
make routes-dashboard DASH_PASS=... ARGS=--delete
```

The dashboard login is `admin`. `apisix` is the Kubernetes namespace, not a
user — logging in as `apisix` fails with "username or password error".

### Locking down the admin route

The gateway does not check roles on `ApproveBilling`, `RejectBilling`,
`AdminListSubscriptions`, `AdminGetSubscription`, `ApproveSubscription` or
`RejectSubscription` — it proxies each one with the caller's own token and
leaves the decision to the billing/subscription service. **Any authenticated
user can reach those endpoints** unless those services reject a non-admin
role. Until you have confirmed they do, restrict the admin route by source:

```bash
make routes ADMIN_ALLOW_CIDRS=10.0.0.0/8,203.0.113.7/32
```

That adds an `ip-restriction` whitelist to `billing-getway-admin` only. With
the variable unset the script prints a warning and leaves the route open —
which is the behaviour of an unconfigured gateway, stated out loud.

### Overrides

Both the Admin API endpoint and the upstream node can be pointed elsewhere —
another namespace, a second APISIX, an Admin API you already have reachable:

```bash
make routes APISIX_ADMIN_URL=http://127.0.0.1:9180 \
            UPSTREAM_NODE=billing-getway-internal.billing.svc.cluster.local:8081
```

Setting `APISIX_ADMIN_URL` also skips the automatic port-forward.

`make routes-delete` removes both routes and the upstream (routes first — an
upstream still referenced by a route cannot be deleted).

## Releasing: tag, build, deploy

Tagging the **app** repo is the whole deploy. There is nothing to run by hand:

```
app repo: git tag prod-v1.2.3 && git push --tags
   |
   +-- master.yml: test -> build -> push  autofikbyslaap/dev.api.billing.getway:prod-1.2.3
   |                                      (also re-tags :production)
   +-- repository_dispatch ------------------> this repo
                                                  |
                          deploy.yml: channel prefix "prod-" selects the
                          environment -> GitHub Environment `prod` holds the
                          job for approval -> terraform apply
                                                  |
                          prod cluster's ArgoCD Application
                                spec.source.kustomize.images   = ...:prod-1.2.3
                                spec.source.kustomize.replicas = 3
                                                  |
                          ArgoCD syncs -> Deployment rolls -> wait for the new
                          image to actually be live, then Healthy
```

Mind the two tag shapes: the **git tag** is `prod-v1.2.3`, the **image tag** it
produces is `prod-1.2.3` (no `v`). Both the workflow and Terraform reject the
wrong one rather than silently deploying nothing.

### The three environments

`dev`, `stg` and `prod` are three **separate clusters**, each running its own
ArgoCD and holding its own Terraform state. One Docker repository serves all
three — the tag prefix is the only thing that distinguishes them, so the legacy
`dev.` in `autofikbyslaap/dev.api.billing.getway` says nothing about which
environment is running an image.

| | dev | stg | prod |
| --- | --- | --- | --- |
| Image tag | `dev-1.2.3` | `stg-1.2.3` | `prod-1.2.3` |
| Replicas | 2 | 2 | 3 |
| Deploy | automatic | automatic | **approval required** |
| State Secret | `tfstate-default-billing-getway-dev` | `…-stg` | `…-prod` |
| Settings | `terraform/envs/dev.tfvars` | `stg.tfvars` | `prod.tfvars` |

Everything else — Application name, namespace, ArgoCD namespace — is identical
in all three, because the cluster is what separates them.

**The environment is never chosen, only derived.** `deploy.yml` reads it from
the tag's channel prefix, and Terraform re-checks the same rule before writing
anything:

```
$ make tf-apply ENV=prod IMAGE_TAG=dev-1.2.3
Error: Invalid value for variable
  image_tag must carry the prod channel prefix (prod-1.2.3). Promote a build by
  re-tagging it in the app repo for this channel - do not point one environment
  at another's image.
```

So there is no dropdown to get wrong, and promoting a build means re-tagging it
in the app repo for the next channel.

### Why Terraform only owns the Application

`terraform/` manages exactly one object per environment — that cluster's ArgoCD
`Application` — and nothing else. The Deployment, Service, ConfigMap and PDB
stay ArgoCD's, synced from `kustomization.yaml` as before.

That is not an arbitrary split. The Application has `selfHeal: true`, so
anything editing the Deployment behind ArgoCD's back is reverted within ~3
minutes. Terraform instead sets the Application's kustomize **image** and
**replica** overrides, which ask ArgoCD to roll the new version out. No two
controllers own the same object, so there is nothing to fight over — and one
manifest serves all three environments without an overlay per cluster.

It also means the deploy is recorded: `spec.source.kustomize.images` on the
live Application always names the exact immutable tag that is running. Pinning
`:master` would not — it is a moving tag, so it produces no diff, ArgoCD sees no
change and deploys nothing. Terraform refuses `master`, `testing`, `production`
and `latest` for that reason.

### One-time setup

Repeat **1** and **2** once per cluster.

**1. Hand that cluster's Application over to Terraform.** If `kubectl apply -f
argocd-application.yaml` already created it, import it — otherwise the first
apply fails with "resource already exists":

```bash
export KUBECONFIG=/path/to/that-cluster/rke2.yaml
make tf-init ENV=prod
cd terraform && terraform import kubernetes_manifest.billing_gateway_app \
  "apiVersion=argoproj.io/v1alpha1,kind=Application,namespace=argocd,name=billing-getway-internal"
```

`make tf-init` uses `-reconfigure`, so switching `ENV` points at that
environment's existing state rather than offering to copy one over another.

**2. A GitHub Environment per cluster** (Settings → Environments), named
exactly `dev`, `stg` and `prod` — `deploy.yml` selects one by the tag's channel
prefix, so the names have to match. Each one holds:

| Environment secret | What |
| --- | --- |
| `KUBECONFIG_B64` | `base64 -w0` of a kubeconfig for **that** cluster. Its `server:` must be reachable from a GitHub runner — RKE2 writes `127.0.0.1`, which is not |

Keeping this as an *Environment* secret rather than a repo secret is what makes
the prod kubeconfig unreachable from a dev deploy. On `prod` only, add
**required reviewers** — that is the approval gate; the job pauses before its
first step, so nothing touches the cluster until someone approves.

**3. Repo-level secrets on this repo** (Settings → Secrets → Actions):
`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` and optionally
`TELEGRAM_MESSAGE_THREAD_ID`, shared by all three environments.

**4. A secret on the *app* repo:** `DEPLOY_DISPATCH_TOKEN`, a PAT with
`contents: write` on this repo. The two repos are in different GitHub orgs
(`autofik-development` and `openLabDnx`), so the built-in `GITHUB_TOKEN` cannot
reach across — this is the one credential that makes the chain work.

### Deploying or rolling back by hand

Every `tf-*` target needs both `ENV` (which state and channel) and `KUBECONFIG`
(which cluster). They are set independently, so `tf-apply` prints the cluster it
is about to write to and asks before doing it:

```bash
export KUBECONFIG=/path/to/prod/rke2.yaml

make tf-plan  ENV=prod IMAGE_TAG=prod-1.2.3   # see what would change first
make tf-apply ENV=prod IMAGE_TAG=prod-1.2.2   # roll back to the previous release
make tf-show  ENV=prod                        # what is pinned right now
```

Pass `YES=1` to skip the confirmation (CI does). Or run the **Deploy released
image** workflow from the Actions tab with a tag — there is no environment to
pick there either, the tag decides.

A rollback is just an older tag of the same channel; the state and the
Application both record what is live.

Terraform state is a Secret in each cluster's `terraform-state` namespace, so
there is no bucket to provision; `make tf-init ENV=<env>` creates that
namespace.

## Day-to-day

```bash
make status     # pods, service, endpoints
make logs       # follow gateway logs
make restart    # roll the Deployment to pick up a new :master image
make undeploy   # delete the workload; routes and Secret are left alone
```

## Health and probes

The binary serves two health surfaces, both exempt from token verification:

- `GET /healty` on `:8081` — a plain handler mounted ahead of the grpc-gateway
  mux, so it never enters the gRPC interceptor chain. The Kubernetes
  startup/readiness/liveness probes use this one.
- `GET /mobile/v1/health` — goes all the way through grpc-gateway into the
  `HealthCheck` RPC, which the interceptor skips by method name. `make verify`
  uses this one, because a 200 proves the entire path works end to end.

(`/healty` is the route the binary actually serves — the spelling is
deliberate, not a typo here.)

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Pod stuck in `CreateContainerConfigError` | `secret.yml` was never applied *in the `billing-gateway` namespace* — run `make secret`. A Secret sitting in `default` does not count |
| `kubectl get pods` shows nothing | everything moved to the `billing-gateway` namespace — add `-n billing-gateway`, or use `make status` |
| Every request 401s with a valid token | `USER_SERVICE_PUBLISHABLE_API_KEY` missing/wrong, or `USER_SERVICE_URL` points somewhere that is not user.auth.sso |
| Subscription/plan calls 400, billing calls fine | `SUBSCRIPTION_SERVICE_PUBLISHABLE_API_KEY` missing |
| APISIX returns 404 | routes were never seeded, or seeded into a different APISIX — `make routes`. A successful ArgoCD sync does **not** seed them |
| Dashboard shows no routes after an ArgoCD deploy | expected — ArgoCD only syncs the workload; run `make routes` or `make routes-dashboard` |
| Admin API returns 401 | the key in `api/ansible/.secrets/apisix_admin_key` is not the key that cluster runs; check `kubectl -n apisix get cm apisix -o yaml` under `deployment.admin.admin_key` |
| APISIX returns 503 | upstream node name does not resolve; check `make status` shows endpoints |
| Auth works for some users, fails for others | known upstream issue: user.auth.sso's `GET /api/user/verify-token` returns *every* verify-token row unfiltered, and the gateway reads `data[0]`. It is only correct while that table holds a single active record — see the note in `middleware/user_auth.go` |
