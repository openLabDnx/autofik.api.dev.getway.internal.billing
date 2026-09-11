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
| `billing-getway.yml` | ConfigMap + Deployment + Service for the gateway |
| `secret.example.yml` | template for the two downstream API keys |
| `kustomization.yaml` | what `kubectl apply -k .` applies |
| `apisix/seed-routes.sh` | writes the upstream + routes through the APISIX Admin API |
| `Makefile` | the commands below |

## Deploy

```bash
export KUBECONFIG=/path/to/rke2.yaml     # on the RKE2 host: /etc/rancher/rke2/rke2.yaml

cp secret.example.yml secret.yml         # fill in both keys - see below
make secret                              # must exist before the pod starts
make deploy                              # ConfigMap + Deployment + Service
make routes                              # APISIX upstream + routes
make verify                              # 200 from /mobile/v1/health through APISIX
```

`make all` runs secret → deploy → routes in one go.

### Before the first deploy, check these three things

1. **Downstream URLs.** The `ConfigMap` in `billing-getway.yml` points at
   `billing.default.svc.cluster.local:4041`,
   `subscription.default.svc.cluster.local:4040` and
   `user-auth-sso.default.svc.cluster.local:4000`. Those Services have no
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
   release. Pin `:dev-<version>` for a reproducible rollout.

## APISIX routes

`apisix/seed-routes.sh` writes three objects through the Admin API. APISIX
runs in `traditional` role with etcd as its config provider, so routes are
etcd entries, not Kubernetes objects — there is no CRD to `kubectl apply`.
The Admin API is ClusterIP-only on port 9180; `make routes` opens its own
`kubectl port-forward` and closes it again, and reads the admin key from
`api/ansible/.secrets/apisix_admin_key`.

| Object | Matches | Notes |
| --- | --- | --- |
| upstream `billing-getway-internal` | — | `billing-getway-internal.default.svc.cluster.local:8081`, 30s read timeout |
| route `billing-getway-mobile` | `/mobile/v1/*` | the public surface, `cors` enabled |
| route `billing-getway-admin` | `/mobile/v1/admin/*`, `/mobile/v1/billings/approve`, `/mobile/v1/billings/reject` | priority 10, optional `ip-restriction` |

Paths are forwarded unchanged — the gateway already serves `/mobile/v1/...`
exactly as `billing.proto` declares it, so there is no `proxy-rewrite`.

`/internal/v1/token/verify` is **not** routed. It is for in-cluster callers
(e.g. the subscription service resolving a caller's identity); they reach it
on the ClusterIP Service directly, never through the edge.

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
| Pod stuck in `CreateContainerConfigError` | `secret.yml` was never applied — run `make secret` |
| Every request 401s with a valid token | `USER_SERVICE_PUBLISHABLE_API_KEY` missing/wrong, or `USER_SERVICE_URL` points somewhere that is not user.auth.sso |
| Subscription/plan calls 400, billing calls fine | `SUBSCRIPTION_SERVICE_PUBLISHABLE_API_KEY` missing |
| APISIX returns 404 | routes were never seeded, or seeded into a different APISIX — `make routes` |
| APISIX returns 503 | upstream node name does not resolve; check `make status` shows endpoints |
| Auth works for some users, fails for others | known upstream issue: user.auth.sso's `GET /api/user/verify-token` returns *every* verify-token row unfiltered, and the gateway reads `data[0]`. It is only correct while that table holds a single active record — see the note in `middleware/user_auth.go` |
