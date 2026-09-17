# billing-getway deploy

Kubernetes deployment for the billing stack — SSO, billing, subscription and
the internal billing gateway — plus the APISIX configuration that fronts it.

```
                  ┌────────────────────────────────────────────────┐
                  │                   cluster                      │
 mobile           │                                                │
  app ──NodePort──┼─► APISIX ─┬─► sso           :4000 ──► postgres, redis
        32756     │  (edge)   │                      └─► Authentik (external)
                  │           │                                    │
                  │           └─► billing-getway :8081 ─┬─► billing      :4041
                  │                  internal   :50055 ─┤   └─► mongodb, redis
                  │                       ▲             └─► subscription :4040
                  │                       │                 └─► mongodb, redis
                  │              in-cluster gRPC callers          │
                  │                                     billing ⇄ subscription
                  │                                      over rabbitmq :5672
                  └────────────────────────────────────────────────┘
```

**Only two things are published.** The SSO service, because the app logs in
against it directly, and the billing gateway, because it is the app's entire
billing API. The billing and subscription services get no APISIX route and no
Ingress — the gateway is the only thing allowed to reach them, and it is what
verifies the caller's token before anything downstream runs.

APISIX authenticates nothing here. It forwards `Authorization` untouched and
the gateway's `UserVerificationUnaryInterceptor` checks it against the SSO
service on every request.

## This cluster

The manifests are written for the cluster that is actually running, which
differs from what `api/ansible` describes — that playbook has not been
applied here. What is really in place:

| What | Where |
| --- | --- |
| PostgreSQL | `postgres.postgres.svc.cluster.local:5432` (namespace `postgres`, not `postgresql`) |
| Redis | `redis.redis.svc.cluster.local:6379` — **password required**, stored inside `redis.conf` |
| MongoDB | `mongodb.mongodb.svc.cluster.local:27017` |
| RabbitMQ | `rabbitmq.rabbitmq.svc.cluster.local:5672` — already deployed, so this repo ships no broker manifest |
| APISIX | Helm release in `apisix`: Admin API on `apisix-admin:9180`, data plane on `apisix-gateway` NodePort **32756** |
| Ingress | none — there is no ingress controller, so the NodePort is the only way in |
| Authentik | not in-cluster; the SSO service talks to the external instance from its own `.env` |
| Jaeger | not deployed — tracing is turned off in both ConfigMaps |

## Files

| File | What it deploys |
| --- | --- |
| `sso-db-init.yml` | Job that creates the `sso` database (idempotent) |
| `sso.yml` | `autofik.dev.api.user.auth.sso` — identity, published |
| `billing.yml` | `autofik.dev.api.billing` — internal |
| `subscription.yml` | `autofik.dev.api.subscription` — internal |
| `billing-getway.yml` | `autofik.dev.api.billing.getway.internal` — published |
| `scripts/build-secrets.sh` | builds every Secret from the cluster + each repo's `.env` |
| `scripts/mongo-create-root.sh` | one-time fix: creates MongoDB's missing root user |
| `apisix/seed-routes.sh` | upstreams + routes, through the APISIX Admin API |
| `kustomization.yaml` | what `kubectl apply -k .` applies |

| Service | Image | Port | Published |
| --- | --- | --- | --- |
| sso | `autofikbyslaap/dev.api.sso:master` | 4000 | `/api/user/*`, `/api/mechanic/*` |
| billing | `autofikbyslaap/dev.api.billing:internal` | 4041 | no |
| subscription | `autofikbyslaap/dev.api.subscription:internal` | 4040 | no — runs in its own `subscription` namespace |
| billing-getway-internal | `autofikbyslaap/dev.api.billing.getway:master` | 8081 / 50055 | `/mobile/v1/*` |

Only `dev.api.sso` and `dev.api.billing.getway` publish a `:master` tag. The
billing repo's `master.yml` workflow is an empty file and the subscription
repo's `dev-v*` workflow has never run, so both are on `:internal` — whatever
`make push` last pushed by hand from those repos.

## Credentials

No credential is stored in this repo. `scripts/build-secrets.sh` assembles
every Secret from sources that already exist and pipes them straight into
`kubectl apply`, printing only key names and byte counts:

- **Datastore credentials** are copied out of the cluster's own Secrets
  (`postgres-admin`, `mongodb-admin`, `rabbitmq-admin`) into the app
  namespace, because a `secretKeyRef` cannot cross namespaces. The pods
  reference those keys and compose their connection URIs with `$(VAR)`
  expansion, so a password never appears in a manifest.
- **Redis** keeps its password inside `redis.conf`, where there is no key to
  reference; the script lifts just the `requirepass` value into a `redis-auth`
  Secret.
- **Application credentials** (Authentik, Medusa, S3, Telegram, Plasgate) come
  from each service repo's `.env`. The whole file is loaded rather than a
  hand-maintained key list — the Deployments list their ConfigMap *after* the
  Secret in `envFrom`, so every cluster-specific key is overridden and the
  `.env` only supplies what the cluster has no opinion about. `DOCKER_*` is
  stripped: a registry PAT has no business in an application pod.
- **`JWT_SECRET`** is not in the SSO repo's `.env` at all, so the script mints
  one — and reuses the existing value on later runs, because rotating it
  invalidates every token that service has issued.

```bash
make secrets-check     # report what it would do, change nothing
make secrets           # create/update all eight Secrets
```

## Deploy

```bash
make secrets    # must exist before any pod can start
make deploy     # db-init Job, ConfigMaps, Deployments, Services
make routes     # APISIX upstreams + routes
make verify     # 200 from /mobile/v1/health through APISIX
```

`make all` runs all three. `make deploy` deletes the db-init Job before
re-applying, because a completed Job is immutable.

Single services deploy on their own, so a change to one never risks rolling
the others:

```bash
make sso
make billing
make subscription
make gateway
```

**A ConfigMap edit alone does not restart anything.** These targets only
`kubectl apply`; if you changed a ConfigMap and the Deployment spec is
otherwise identical, Kubernetes sees no new revision and the running pod keeps
its old environment. Follow with `make restart SERVICE=<name>`.

### Namespaces

`subscription` runs in a namespace of its own; everything else is in
`default`. A `secretKeyRef` cannot cross namespaces, so `mongodb-admin`,
`rabbitmq-admin` and `redis-auth` are copied into *both* by
`scripts/build-secrets.sh`, which also creates the namespace if it is missing
(it has to exist before a Secret can be put in it). The gateway reaches the
service at `subscription.subscription.svc.cluster.local:4040`; moving a
service between namespaces means updating that URL in `billing-getway.yml`
and restarting the gateway.

## APISIX routes

`apisix/seed-routes.sh` writes two upstreams and three routes through the
Admin API. APISIX is etcd-backed, so routes are etcd entries, not Kubernetes
objects — there is no CRD to `kubectl apply`. The Admin API is ClusterIP-only;
`make routes` opens its own `kubectl port-forward` and closes it again, and
reads the admin key out of the running `apisix` ConfigMap so it follows the
Helm release if the key is rotated.

| Route | Matches | Upstream |
| --- | --- | --- |
| `billing-getway-mobile` | `/mobile/v1/*` | gateway :8081 |
| `billing-getway-admin` | `/mobile/v1/admin/*`, `/mobile/v1/billings/approve`, `/mobile/v1/billings/reject` | gateway :8081, priority 10 |
| `sso-public` | `/api/user/*`, `/api/mechanic/*` | sso :4000 |

Paths are forwarded unchanged — the gateway already serves `/mobile/v1/...`
exactly as `billing.proto` declares it, so there is no `proxy-rewrite` and no
`grpc-transcode` plugin; the gateway transcodes REST ⇄ gRPC itself.

Two paths are deliberately **not** routed:

- `/internal/v1/token/verify` on the gateway — for in-cluster callers, which
  reach it on the ClusterIP Service.
- `/webhook/*` on the SSO service — its only caller is Authentik, which should
  be pointed at `http://sso.default.svc.cluster.local:4000/webhook/authentik/sms`.
  There is no reason to expose an SMS webhook to the internet.

### Locking down the admin route

The gateway does not check roles on `ApproveBilling`, `RejectBilling`,
`AdminListSubscriptions`, `AdminGetSubscription`, `ApproveSubscription` or
`RejectSubscription` — it proxies each with the caller's own token and leaves
the decision to the billing/subscription service. **Any authenticated user can
reach those endpoints** unless those services reject a non-admin role. Until
that is confirmed, restrict the admin route by source:

```bash
make routes ADMIN_ALLOW_CIDRS=10.0.0.0/8,203.0.113.7/32
```

With the variable unset the script warns and leaves the route open.

## Day-to-day

```bash
make status                              # the whole stack
make logs SERVICE=sso                    # sso | billing | subscription | billing-getway-internal
make restart SERVICE=billing             # roll one service
make undeploy                            # delete the workloads; Secrets and routes are left alone
```

## Before this is production-shaped

- **`PUBLIC_API_URL` is a NodePort address** (`http://10.10.10.1:32756`) in
  `sso.yml`, because the cluster has no ingress controller. It must match what
  is registered on the Authentik provider — as must the redirect URIs, which
  come from the SSO repo's `.env` untouched.
- **MongoDB uses the root account** with `authSource=admin` for both
  databases; that is the only account the cluster's MongoDB Secret describes.
  Per-service users would be better.
- **PostgreSQL uses the admin account** for the SSO service, for the same
  reason.

## Known integration gaps

Real today, in the services' own code — worth knowing before debugging a
deployment that is actually fine.

- **The gateway never sends `service-code`.** The SSO verify-token controller
  rejects a request with `INVALID_SERVICE_CODE` when the user's record has a
  `serviceCode` set and the header does not match. Users whose record has none
  are unaffected; for anyone else every billing request fails. Fixing it means
  a change in the gateway's `middleware/user_auth.go`.
- **One incomplete session blocks a user everywhere.** That controller 401s if
  *any* of the user's verify-token rows has `otpVerify` or `profileVerify`
  false, not just the row for the current device.
- **The gateway reads `data[0]`.** The SSO side filters by the authenticated
  user, so it is the right user — but with several active devices it is an
  arbitrary one of their sessions, and the `deviceId` forwarded downstream may
  not be the device that made the call.
- **`USER_SERVICE_PUBLISHABLE_API_KEY` does nothing yet.** The gateway sends
  `x-publishable-api-key` on every verify, but the SSO service has no
  publishable-key middleware at all. It is left empty.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Pod in `CreateContainerConfigError` | its Secret does not exist — `make secrets` |
| billing / subscription crash-loop on boot | RabbitMQ unreachable — their consumers rethrow on a failed subscribe |
| sso crash-loops with a TypeORM connect error | the `sso` database is missing — re-run the db-init Job |
| sso readiness fails, `/health` returns 503 | PostgreSQL or Redis unreachable — the body names which |
| Every billing request 401s with a valid token | SSO unreachable from the gateway, or the `service-code` mismatch above |
| Subscription/plan calls 400, billing calls fine | the gateway's `SUBSCRIPTION_SERVICE_PUBLISHABLE_API_KEY` and the subscription service's `MEDUSA_PUBLISHABLE_API_KEY` differ |
| Mongo `Authentication failed` for every credential, including MongoDB's own | no user exists — the image only runs `MONGO_INITDB_ROOT_*` on an empty data dir, and this PVC was not. `./scripts/mongo-create-root.sh --check` confirms it; run it without `--check` to fix |
| `deployment "x" exceeded its progress deadline` | the pod spent longer than `progressDeadlineSeconds` (600s) not-Ready — usually waiting on a Secret. Harmless once the pod is Ready; re-run `make deploy` to clear the condition |
| APISIX returns 404 | no route matched — `make routes` |
| APISIX returns 502/503 | route matched but the upstream has no ready pod — `make status` |
