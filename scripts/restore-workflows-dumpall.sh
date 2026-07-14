#!/usr/bin/env bash
# restore-workflows-dumpall.sh -- load the shipped workflow database seed into
# the (fresh, empty) n8n Postgres.
#
# The n8n Postgres (CNPG cluster graphrag-postgres-n8n, graphrag ns) is freshly
# initdb'd on every build, so there is nothing worth backing up: we just drop
# any database that's there and load the seed. The seed is the plain-SQL
# pg_dumpall named
#   $HOME/workflows-pg-dumpall-<date>-v<N>.sql
# (e.g. $HOME/workflows-pg-dumpall-2026-07-13-v17.sql), placed in the EC2 home
# root -- scp'd up by the operator, or produced by create-workflows-dumpall.sh.
# If several dumps are present we load the NEWEST by the date + version embedded
# in the filename (version sort), not mtime.
#
# Gated: if no matching file is present, this is a no-op (exit 0), so it
# is safe to call unconditionally at the end of deploy-stack.sh.
#
# Run from: the EC2, after the stack is up (Postgres + n8n Running).
set -euo pipefail

if [ -t 1 ]; then BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""; fi

NS=graphrag
CLUSTER=graphrag-postgres-n8n
DEPLOY=graphrag-workflows

# Discover the seed in the EC2 home root, newest by the date + version in the
# filename (`sort -V | tail -1`). Nothing there -> no-op (n8n starts empty);
# there is NO fallback -- the seed is not shipped in the repo/clone.
DUMP="$(ls -1 "$HOME"/workflows-pg-dumpall*.sql 2>/dev/null | sort -V | tail -1 || true)"
if [ -z "$DUMP" ] || [ ! -f "$DUMP" ]; then
    echo "${YELLOW}restore-workflows-dumpall:${RESET} no \$HOME/workflows-pg-dumpall*.sql found -- skipping (nothing to load)."
    exit 0
fi

echo "${BOLD}Restoring n8n workflow DB from $(basename "$DUMP")...${RESET}"

echo "  waiting for the n8n Postgres primary + n8n deployment to be Ready..."
kubectl -n "$NS" wait --for=condition=Ready pod -l "cnpg.io/cluster=$CLUSTER,role=primary" --timeout=300s
kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout=300s || true

PGPOD=$(kubectl -n "$NS" get pod -l "cnpg.io/cluster=$CLUSTER,role=primary" -o jsonpath='{.items[0].metadata.name}')
PGPW=$(kubectl -n "$NS" get secret n8n-postgres-superuser -o jsonpath='{.data.password}' | base64 -d)
# The password the n8n app authenticates with (re-asserted after load, since the
# dump's globals set the n8n role password to the *source's* hash).
N8NPW=$(kubectl -n "$NS" get secret graphrag-n8n-database-credentials -o jsonpath='{.data.DB_POSTGRESDB_PASSWORD}' | base64 -d)

echo "  scaling n8n to 0 (release DB connections during the load)..."
kubectl -n "$NS" scale "deploy/$DEPLOY" --replicas=0
kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout=120s || true

echo "  dropping the existing n8n database (empty on a fresh build)..."
kubectl -n "$NS" exec "$PGPOD" -- env PGPASSWORD="$PGPW" \
    psql -U postgres -d postgres -c 'DROP DATABASE IF EXISTS n8n WITH (FORCE);'

echo "  loading the dump (pg_dumpall via psql)..."
cat "$DUMP" | kubectl -n "$NS" exec -i "$PGPOD" -- env PGPASSWORD="$PGPW" \
    psql -U postgres -d postgres -v ON_ERROR_STOP=0 2> /tmp/n8n-restore.err
UNEXPECTED=$(grep -i ERROR /tmp/n8n-restore.err | grep -vi 'already exists' || true)
if [ -n "$UNEXPECTED" ]; then
    echo "${RED}  unexpected restore errors (beyond the harmless role-already-exists):${RESET}"
    echo "$UNEXPECTED" | sed 's/^/    /'
fi

echo "  re-asserting the n8n app-role password + public grants..."
kubectl -n "$NS" exec "$PGPOD" -- env PGPASSWORD="$PGPW" psql -U postgres -d postgres \
    -c "ALTER ROLE n8n WITH LOGIN PASSWORD '${N8NPW}';"
kubectl -n "$NS" exec "$PGPOD" -- env PGPASSWORD="$PGPW" psql -U postgres -d n8n <<'SQL'
GRANT USAGE, CREATE ON SCHEMA public TO n8n;
GRANT ALL ON ALL TABLES    IN SCHEMA public TO n8n;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO n8n;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO n8n;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO n8n;
SQL

echo "  sanity counts:"
kubectl -n "$NS" exec "$PGPOD" -- env PGPASSWORD="$PGPW" psql -U postgres -d n8n \
    -c 'select count(*) as workflows   from workflow_entity;' \
    -c 'select count(*) as credentials from credentials_entity;' 2>/dev/null || true

echo "  scaling n8n back up..."
kubectl -n "$NS" scale "deploy/$DEPLOY" --replicas=1
kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout=180s
echo "${GREEN}restore-workflows-dumpall: done.${RESET}"
