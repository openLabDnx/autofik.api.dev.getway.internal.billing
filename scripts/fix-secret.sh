#!/usr/bin/env bash
# Create the billing-getway-internal Secret that the Deployment pulls in with
# envFrom, and unstick any pod sitting in CreateContainerConfigError.
#
# The pod cannot start until this Secret EXISTS - the kubelet refuses to build
# the container environment for a `secretRef` with `optional: false`. The
# values matter for runtime behaviour, not for whether the pod starts.
#
# This needs cluster access; there is no way to create a Secret without it.
#
#   KUBECONFIG=/etc/rancher/rke2/rke2.yaml ./scripts/fix-secret.sh
#   NAMESPACE=default ./scripts/fix-secret.sh          # pre-namespace-move
#   CONTEXT=master ./scripts/fix-secret.sh             # pick a context
#   DRY_RUN=1 ./scripts/fix-secret.sh                  # show, change nothing
set -euo pipefail

NAMESPACE="${NAMESPACE:-billing-gateway}"
SECRET_NAME="${SECRET_NAME:-billing-getway-internal}"
SECRET_FILE="${SECRET_FILE:-$(dirname "$0")/../secret.yml}"
KUBECTL="${KUBECTL:-kubectl}"
[ -n "${CONTEXT:-}" ] && KUBECTL="$KUBECTL --context=$CONTEXT"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$SECRET_FILE" ] || die "$SECRET_FILE not found - cp secret.example.yml secret.yml and fill it in"

# Refuse to act on the wrong cluster by accident: the whole point of this
# script is that it runs somewhere other than the local dev cluster.
CURRENT_CTX="$($KUBECTL config current-context 2>/dev/null || echo unknown)"
SERVER="$($KUBECTL config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo unknown)"
say "context : $CURRENT_CTX"
say "server  : $SERVER"
say "target  : namespace/$NAMESPACE secret/$SECRET_NAME"

if [ -n "${DRY_RUN:-}" ]; then
  say "DRY_RUN set - nothing will be changed"
  exit 0
fi

if [ -z "${YES:-}" ]; then
  read -r -p "Apply to the cluster above? [y/N] " ans
  case "$ans" in [yY]*) ;; *) die "aborted" ;; esac
fi

# 1. Namespace. Idempotent: apply, not create, so a re-run is not an error.
say "ensuring namespace $NAMESPACE"
$KUBECTL create namespace "$NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -

# 2. Secret. Force the namespace on the way in so the file's own metadata
#    cannot send it somewhere unexpected.
say "applying $SECRET_FILE"
$KUBECTL -n "$NAMESPACE" apply -f "$SECRET_FILE"

# 3. Report which keys landed, without ever printing their values.
say "keys now present:"
$KUBECTL -n "$NAMESPACE" get secret "$SECRET_NAME" \
  -o go-template='{{range $k,$v := .data}}    {{$k}} ({{len $v}} b64 chars){{"\n"}}{{end}}'

# 4. Unstick pods already wedged in CreateContainerConfigError. The kubelet
#    retries on its own, but deleting them makes the fix immediate.
STUCK="$($KUBECTL -n "$NAMESPACE" get pods -l app=billing-getway-internal \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
  | awk '$2=="CreateContainerConfigError"{print $1}' || true)"

if [ -n "$STUCK" ]; then
  say "deleting stuck pods: $STUCK"
  # shellcheck disable=SC2086
  $KUBECTL -n "$NAMESPACE" delete pod $STUCK
else
  say "no pods in CreateContainerConfigError"
fi

say "waiting for rollout"
$KUBECTL -n "$NAMESPACE" rollout status deployment/billing-getway-internal --timeout=180s || {
  say "rollout did not finish - recent events:"
  $KUBECTL -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -15
  exit 1
}

say "done. Remember: if the namespace changed, re-seed the APISIX routes"
say "      (make routes) - the upstream in etcd still holds the old DNS name."
