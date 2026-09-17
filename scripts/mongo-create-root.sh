#!/usr/bin/env bash
#
# Create MongoDB's root user, matching the cluster's mongodb-admin Secret.
#
# Why this is needed: the mongo image only runs MONGO_INITDB_ROOT_USERNAME /
# MONGO_INITDB_ROOT_PASSWORD when it initialises an *empty* data directory.
# On this cluster the mongodb-data PVC already had WiredTiger files by the
# time those variables were wired in, so the user was never created while
# access control stayed on. mongod says so itself on every connection:
#
#   "note: no users configured in admin.system.users, allowing localhost
#    access"
#
# The symptom is that *every* credential fails with "Authentication failed",
# including the one MongoDB is configured with - which looks like a wrong
# password but is actually a missing user.
#
# This has to run as `kubectl exec` inside the mongod pod: MongoDB's localhost
# exception (the one thing an unauthenticated client may do when no users
# exist - create the first user) only applies to connections from the loopback
# interface, so a Job talking to the Service would be rejected.
#
# The credentials are read from the pod's own environment, so no password is
# typed, printed, or passed through a shell argument.
#
# Usage:
#   ./scripts/mongo-create-root.sh
#   ./scripts/mongo-create-root.sh --check    # report only, create nothing
set -euo pipefail

NAMESPACE="${MONGO_NAMESPACE:-mongodb}"
DEPLOY="${MONGO_DEPLOY:-deploy/mongodb}"

if [ "${1:-}" = "--check" ]; then
  echo "Checking whether MongoDB has any users..."
  # grep -c, not grep -q: -q exits on the first match, kubectl then takes
  # SIGPIPE, and `set -o pipefail` turns that into a failed pipeline - which
  # would report "no notice found" every time the notice *is* there.
  notice_count=$(kubectl -n "$NAMESPACE" logs "$DEPLOY" 2>/dev/null |
                   grep -c "no users configured in admin.system.users" || true)
  if [ "${notice_count:-0}" -gt 0 ]; then
    echo "  NO USERS - the root user is missing; run this script without --check"
  else
    echo "  mongod has not logged the localhost-exception notice"
    echo "  (either a user exists already, or the pod has been restarted since)"
  fi
  echo "Authentication test:"
  if kubectl -n "$NAMESPACE" exec "$DEPLOY" -- sh -c \
      'mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --eval "db.runCommand({ping:1}).ok"' \
      >/dev/null 2>&1; then
    echo "  configured credentials authenticate OK - nothing to do"
  else
    echo "  configured credentials FAIL to authenticate"
  fi
  exit 0
fi

echo "Creating the root user from the pod's own MONGO_INITDB_ROOT_* variables..."

kubectl -n "$NAMESPACE" exec "$DEPLOY" -- sh -c '
  mongosh --quiet admin --eval "
    const u = process.env.MONGO_INITDB_ROOT_USERNAME;
    const p = process.env.MONGO_INITDB_ROOT_PASSWORD;
    if (!u || !p) { print(\"MONGO_INITDB_ROOT_* not set in this pod\"); quit(1); }
    try {
      db.createUser({ user: u, pwd: p, roles: [{ role: \"root\", db: \"admin\" }] });
      print(\"created root user \" + u);
    } catch (e) {
      if (String(e).includes(\"already exists\")) { print(\"user \" + u + \" already exists\"); }
      else { print(\"failed: \" + e); quit(1); }
    }
  "
'

echo "Verifying..."
kubectl -n "$NAMESPACE" exec "$DEPLOY" -- sh -c \
  'mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --eval "print(\"auth ok: \" + db.runCommand({ping:1}).ok)"'

echo
echo "Now restart the two services that were failing to connect:"
echo "  kubectl -n default rollout restart deployment/billing deployment/subscription"
