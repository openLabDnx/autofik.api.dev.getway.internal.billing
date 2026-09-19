#!/usr/bin/env bash
#
# Same routes as seed-routes.sh, but written through the APISIX *Dashboard*
# API instead of the Admin API.
#
# Use this when you cannot reach the cluster's Admin API: it is ClusterIP-only
# and its allow_admin list is 127.0.0.1/24, so without a kubeconfig for that
# cluster there is no port-forward to open. The dashboard is published over
# HTTPS, speaks the same /apisix/admin/* paths, and writes to the same etcd -
# it just authenticates with a JWT from username/password instead of X-API-KEY.
#
# Usage:
#   DASH_URL=https://apisix.master.autofik.com \
#   DASH_USER=admin DASH_PASS=<password> ./seed-routes-dashboard.sh
#
#   ... ./seed-routes-dashboard.sh --delete    # remove everything
#   ... ./seed-routes-dashboard.sh --dry-run   # print what would be sent
#
# Environment:
#   DASH_URL            required, e.g. https://apisix.master.autofik.com
#   DASH_USER           default admin
#   DASH_PASS           required
#   UPSTREAM_NODE       default billing-getway-internal.billing-gateway.svc.cluster.local:8081
#   ADMIN_ALLOW_CIDRS   optional, comma-separated; wraps the admin route in
#                       ip-restriction so only these CIDRs can call it.
set -euo pipefail

DASH_URL="${DASH_URL:-}"
DASH_USER="${DASH_USER:-admin}"
DASH_PASS="${DASH_PASS:-}"
UPSTREAM_NODE="${UPSTREAM_NODE:-billing-getway-internal.billing-gateway.svc.cluster.local:8081}"
ADMIN_ALLOW_CIDRS="${ADMIN_ALLOW_CIDRS:-}"

UPSTREAM_ID="billing-getway-internal"
ROUTE_MOBILE_ID="billing-getway-mobile"
ROUTE_ADMIN_ID="billing-getway-admin"

MODE="${1:-}"
DRY_RUN=0
[ "$MODE" = "--dry-run" ] && DRY_RUN=1

if [ -z "$DASH_URL" ] || [ -z "$DASH_PASS" ]; then
  echo "DASH_URL and DASH_PASS are required" >&2
  exit 1
fi
DASH_URL="${DASH_URL%/}"

# The dashboard hands out a JWT that expires after an hour; one login per run
# is plenty. A wrong password comes back as HTTP 200 with code != 0, so the
# code is what has to be checked, not the status.
TOKEN=""
login() {
  local response
  response=$(curl -sS --max-time 20 -X POST "${DASH_URL}/apisix/admin/user/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${DASH_USER}\",\"password\":\"${DASH_PASS}\"}")
  TOKEN=$(printf '%s' "$response" | python3 -c '
import json,sys
d=json.load(sys.stdin)
if d.get("code") != 0:
    sys.stderr.write("login failed: %s\n" % d.get("message"))
    sys.exit(1)
print(d["data"]["token"])
')
  echo "Logged in to ${DASH_URL} as ${DASH_USER}"
}

# call <method> <path> [body]
# Non-2xx, or a 2xx carrying a non-zero dashboard code, aborts the run with
# the body printed - a silently rejected route is how you end up with a
# gateway that 404s in production for no visible reason.
call() {
  local method="$1" path="$2" body="${3:-}" response status

  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] ${method} ${path}"
    [ -n "$body" ] && printf '%s\n' "$body" | sed 's/^/      /'
    return 0
  fi

  if [ -n "$body" ]; then
    response=$(curl -sS --max-time 30 -w $'\n%{http_code}' -X "$method" "${DASH_URL}${path}" \
      -H "Authorization: ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$body")
  else
    response=$(curl -sS --max-time 30 -w $'\n%{http_code}' -X "$method" "${DASH_URL}${path}" \
      -H "Authorization: ${TOKEN}")
  fi

  status="${response##*$'\n'}"
  body="${response%$'\n'*}"

  case "$status" in
    2*)
      # The dashboard reports its own errors inside a 200 envelope.
      if printf '%s' "$body" | grep -q '"code":[^0]'; then
        echo "  ${method} ${path} -> ${status} but ${body}" >&2
        return 1
      fi
      echo "  ${method} ${path} -> ${status}"
      ;;
    404)
      if [ "$method" = "DELETE" ]; then
        echo "  ${method} ${path} -> 404 (already gone)"
      else
        echo "  ${method} ${path} -> ${status}: ${body}" >&2
        return 1
      fi
      ;;
    *)
      echo "  ${method} ${path} -> ${status}: ${body}" >&2
      return 1
      ;;
  esac
}

[ "$DRY_RUN" = "1" ] || login

if [ "$MODE" = "--delete" ]; then
  echo "Removing billing gateway routes from ${DASH_URL}"
  # Routes first: an upstream still referenced by a route cannot be deleted.
  call DELETE "/apisix/admin/routes/${ROUTE_ADMIN_ID}"
  call DELETE "/apisix/admin/routes/${ROUTE_MOBILE_ID}"
  call DELETE "/apisix/admin/upstreams/${UPSTREAM_ID}"
  echo "Done."
  exit 0
fi

echo "Seeding billing gateway routes into ${DASH_URL}"
echo "  upstream node: ${UPSTREAM_NODE}"

call PUT "/apisix/admin/upstreams/${UPSTREAM_ID}" "$(cat <<EOF
{
  "id": "${UPSTREAM_ID}",
  "name": "billing-getway-internal",
  "desc": "autofik.dev.api.billing.getway.internal - grpc-gateway REST listener",
  "type": "roundrobin",
  "scheme": "http",
  "pass_host": "pass",
  "timeout": { "connect": 5, "send": 30, "read": 30 },
  "nodes": { "${UPSTREAM_NODE}": 1 }
}
EOF
)"

call PUT "/apisix/admin/routes/${ROUTE_MOBILE_ID}" "$(cat <<EOF
{
  "id": "${ROUTE_MOBILE_ID}",
  "name": "billing-getway-mobile",
  "desc": "Mobile REST surface of the internal billing gateway",
  "uri": "/mobile/v1/*",
  "methods": ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"],
  "priority": 0,
  "status": 1,
  "upstream_id": "${UPSTREAM_ID}",
  "plugins": {
    "cors": {
      "allow_origins": "*",
      "allow_methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS,HEAD",
      "allow_headers": "Authorization,Content-Type,Accept,x-publishable-api-key",
      "max_age": 3600,
      "allow_credential": false
    }
  }
}
EOF
)"

admin_plugins='{
    "cors": {
      "allow_origins": "*",
      "allow_methods": "GET,POST,OPTIONS",
      "allow_headers": "Authorization,Content-Type,Accept,x-publishable-api-key",
      "max_age": 3600,
      "allow_credential": false
    }'

if [ -n "$ADMIN_ALLOW_CIDRS" ]; then
  whitelist=$(printf '%s' "$ADMIN_ALLOW_CIDRS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
    grep -v '^$' | sed 's/.*/"&"/' | paste -sd, -)
  admin_plugins="${admin_plugins},
    \"ip-restriction\": { \"whitelist\": [${whitelist}] }"
  echo "  admin routes restricted to: ${ADMIN_ALLOW_CIDRS}"
else
  echo "  WARNING: ADMIN_ALLOW_CIDRS is unset - the admin endpoints are"
  echo "           reachable by any authenticated caller from the internet."
fi

admin_plugins="${admin_plugins}
  }"

call PUT "/apisix/admin/routes/${ROUTE_ADMIN_ID}" "$(cat <<EOF
{
  "id": "${ROUTE_ADMIN_ID}",
  "name": "billing-getway-admin",
  "desc": "Admin surface of the internal billing gateway",
  "uris": [
    "/mobile/v1/admin/*",
    "/mobile/v1/billings/approve",
    "/mobile/v1/billings/reject"
  ],
  "methods": ["GET", "POST", "OPTIONS"],
  "priority": 10,
  "status": 1,
  "upstream_id": "${UPSTREAM_ID}",
  "plugins": ${admin_plugins}
}
EOF
)"

echo "Done. The routes should now be visible in the dashboard under Route."
