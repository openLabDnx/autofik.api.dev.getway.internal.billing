#!/usr/bin/env bash
#
# Build every Secret this stack needs, from sources that already exist:
#
#   * the cluster's own datastore Secrets (postgres-admin, mongodb-admin,
#     rabbitmq-admin, and the requirepass line inside redis-config), copied
#     into the app namespace so the pods can reference them - Secrets are
#     namespace-scoped, there is no cross-namespace secretKeyRef;
#   * each service repo's .env, which is where the Authentik / Medusa / S3 /
#     Telegram / Plasgate credentials already live.
#
# Nothing is printed and nothing is written into this repo: values move from
# the cluster (or a .env) straight into `kubectl apply` through a pipe. The
# script only ever reports key names and byte counts.
#
# Usage:
#   ./scripts/build-secrets.sh            # create/update every Secret
#   ./scripts/build-secrets.sh --check    # report what exists, change nothing
#
# Environment:
#   NAMESPACE   where the app Secrets land (default: default)
#   API_DIR     where the service repos are (default: ../../api relative to
#               this repo)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-default}"
# The subscription service runs in its own namespace. A secretKeyRef cannot
# cross namespaces, so every datastore Secret it reads has to be copied there
# as well as into NAMESPACE.
SUBSCRIPTION_NAMESPACE="${SUBSCRIPTION_NAMESPACE:-subscription}"
API_DIR="${API_DIR:-$(cd "${REPO_ROOT}/../../api" 2>/dev/null && pwd || true)}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

say() { printf '  %s\n' "$*"; }

# apply <<< a manifest on stdin, or report it when --check.
apply_stdin() {
  if [ "$CHECK_ONLY" = "1" ]; then
    cat >/dev/null
    say "would apply: $1"
  else
    kubectl apply -f - >/dev/null
    say "applied: $1"
  fi
}

# ---------------------------------------------------------------------------
# 1. Datastore credentials the cluster already holds.
# ---------------------------------------------------------------------------
echo "Datastore Secrets -> namespaces ${NAMESPACE}, ${SUBSCRIPTION_NAMESPACE}"

# The target namespace has to exist before a Secret can be created in it. The
# subscription namespace normally arrives with `kubectl apply -k .`, but this
# script is meant to run *before* that, so create it here if it is missing.
ensure_namespace() {
  local ns="$1"
  kubectl get namespace "$ns" >/dev/null 2>&1 && return 0
  if [ "$CHECK_ONLY" = "1" ]; then
    say "would create namespace ${ns}"
  else
    kubectl create namespace "$ns" >/dev/null
    say "created namespace ${ns}"
  fi
}

ensure_namespace "$NAMESPACE"
ensure_namespace "$SUBSCRIPTION_NAMESPACE"

# copy_secret <source-namespace> <name> <dest-namespace>...
copy_secret() {
  local src_ns="$1" name="$2"
  shift 2
  if ! kubectl -n "$src_ns" get secret "$name" >/dev/null 2>&1; then
    say "MISSING: ${src_ns}/${name} - skipped"
    return 0
  fi
  local dest
  for dest in "$@"; do
    kubectl -n "$src_ns" get secret "$name" -o json |
      python3 -c "
import json, sys
s = json.load(sys.stdin)
# Keep only the data; drop every cluster-assigned field so this applies
# cleanly into another namespace.
s['metadata'] = {
    'name': s['metadata']['name'],
    'namespace': '${dest}',
    'labels': {'app.kubernetes.io/managed-by': 'billing-getway-deploy'},
}
s.pop('status', None)
json.dump(s, sys.stdout)
" | apply_stdin "${name} -> ${dest} (from ${src_ns})"
  done
}

# postgres is only read by sso, which stays in NAMESPACE. Mongo and RabbitMQ
# are read by billing (NAMESPACE) and subscription (its own namespace).
copy_secret postgres postgres-admin "$NAMESPACE"
copy_secret mongodb mongodb-admin "$NAMESPACE" "$SUBSCRIPTION_NAMESPACE"
copy_secret rabbitmq rabbitmq-admin "$NAMESPACE" "$SUBSCRIPTION_NAMESPACE"

# Redis stores its password inside redis.conf, so there is no key for a pod to
# reference. Lift just the requirepass value into its own Secret.
if kubectl -n redis get secret redis-config >/dev/null 2>&1; then
  kubectl -n redis get secret redis-config -o jsonpath='{.data.redis\.conf}' |
    base64 -d |
    awk '/^[[:space:]]*requirepass[[:space:]]/ {print $2; found=1} END {exit found?0:3}' |
    tr -d '\r\n' > "$WORK/redis_pw" || {
      say "no requirepass in redis-config - redis-auth not created"
      : > "$WORK/redis_pw"
    }
  if [ -s "$WORK/redis_pw" ]; then
    for ns in "$NAMESPACE" "$SUBSCRIPTION_NAMESPACE"; do
      kubectl -n "$ns" create secret generic redis-auth \
        --from-file=password="$WORK/redis_pw" \
        --dry-run=client -o yaml | apply_stdin "redis-auth -> ${ns} ($(wc -c < "$WORK/redis_pw") bytes)"
    done
  fi
else
  say "MISSING: redis/redis-config - redis-auth not created"
fi

# ---------------------------------------------------------------------------
# 2. Application credentials, from each service repo's .env.
#
# The whole .env is loaded rather than a hand-maintained key list: the
# Deployments list their ConfigMap *after* the Secret in envFrom, so every
# cluster-specific key (DB_HOST, REDIS_URL, ports, Jaeger...) is overridden by
# the ConfigMap, and the .env only supplies what the cluster has no opinion
# about - the actual credentials. DOCKER_* is stripped: a registry PAT has no
# business in an application pod.
# ---------------------------------------------------------------------------
echo "Application Secrets"

# env_secret <name> <env-file> <dest-namespace> [EXTRA_KEY=value...]
env_secret() {
  local name="$1" env_file="$2" ns="$3"
  shift 3
  if [ ! -f "$env_file" ]; then
    say "MISSING: ${env_file} - ${name} not created"
    return 0
  fi

  # Keep only well-formed KEY=VALUE lines, drop comments/blanks and the
  # Docker Hub push credentials.
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" |
    grep -vE '^(DOCKER_USERNAME_LOGIN|DOCKER_USERNAME_TAG|DOCKER_TOKEN|IMAGE_NAME|IMAGE_TAG)=' \
    > "$WORK/$name.env" || true

  # Extra literals (KEY=VALUE) passed by the caller.
  for extra in "$@"; do
    printf '%s\n' "$extra" >> "$WORK/$name.env"
  done

  say "${name}: $(wc -l < "$WORK/$name.env") keys from $(basename "$(dirname "$env_file")")/.env"
  kubectl -n "$ns" create secret generic "$name" \
    --from-env-file="$WORK/$name.env" \
    --dry-run=client -o yaml | apply_stdin "${name} -> ${ns}"
}

# A rotated JWT_SECRET invalidates every token this service has issued, so an
# existing one is reused and a new one only minted on the first run. The sso
# repo's .env carries no JWT_SECRET at all, hence generating one here.
keep_or_generate() {
  local secret="$1" key="$2" out="$3"
  if kubectl -n "$NAMESPACE" get secret "$secret" -o jsonpath="{.data.$key}" 2>/dev/null |
       base64 -d > "$out" 2>/dev/null && [ -s "$out" ]; then
    say "${key}: reusing existing value"
  else
    openssl rand -hex 32 | tr -d '\n' > "$out"
    say "${key}: generated a new value"
  fi
}

keep_or_generate sso JWT_SECRET "$WORK/jwt_secret"
keep_or_generate sso AUTHENTIK_SMS_WEBHOOK_TOKEN "$WORK/sms_token"

env_secret sso "${API_DIR}/autofik.dev.api.user.auth.sso/.env" "$NAMESPACE" \
  "JWT_SECRET=$(cat "$WORK/jwt_secret")" \
  "AUTHENTIK_SMS_WEBHOOK_TOKEN=$(cat "$WORK/sms_token")"

env_secret billing "${API_DIR}/autofik.dev.api.billing/.env" "$NAMESPACE"
env_secret subscription "${API_DIR}/autofik.dev.api.subscription/.env" "$SUBSCRIPTION_NAMESPACE"

# The gateway's only credentials are the publishable keys it forwards. The
# subscription one must match that service's own MEDUSA_PUBLISHABLE_API_KEY or
# every plan/subscription call 400s, so it is read from the same .env rather
# than typed twice. The SSO service has no publishable-key middleware today,
# so that one stays empty.
SUB_ENV="${API_DIR}/autofik.dev.api.subscription/.env"
if [ -f "$SUB_ENV" ]; then
  sed -n 's/^MEDUSA_PUBLISHABLE_API_KEY=//p' "$SUB_ENV" | head -1 | tr -d '\r\n' \
    > "$WORK/sub_pk"
else
  : > "$WORK/sub_pk"
fi
say "billing-getway-internal: subscription publishable key $(wc -c < "$WORK/sub_pk") bytes"
kubectl -n "$NAMESPACE" create secret generic billing-getway-internal \
  --from-literal=USER_SERVICE_PUBLISHABLE_API_KEY="" \
  --from-file=SUBSCRIPTION_SERVICE_PUBLISHABLE_API_KEY="$WORK/sub_pk" \
  --dry-run=client -o yaml | apply_stdin "billing-getway-internal"

echo
if [ "$CHECK_ONLY" = "1" ]; then
  echo "--check: nothing was written."
else
  echo "namespace ${NAMESPACE}:"
  kubectl -n "$NAMESPACE" get secret \
    postgres-admin mongodb-admin rabbitmq-admin redis-auth \
    sso billing billing-getway-internal 2>&1 | sed 's/^/  /'
  echo "namespace ${SUBSCRIPTION_NAMESPACE}:"
  kubectl -n "$SUBSCRIPTION_NAMESPACE" get secret \
    mongodb-admin rabbitmq-admin redis-auth subscription 2>&1 | sed 's/^/  /'
fi
