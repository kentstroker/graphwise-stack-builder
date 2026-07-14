#!/usr/bin/env bash
# create-workflows-dumpall.sh -- snapshot the live workflow database into a
# pg_dumpall plain-SQL file that restore-workflows-dumpall.sh can reload.
#
# Output: $HOME/workflows-pg-dumpall-<date>.sql (EC2 home root, uncompressed).
# restore-workflows-dumpall.sh loads the NEWEST $HOME/workflows-pg-dumpall*.sql,
# so a fresh dump created here is picked up on the next restore.
#
# Run from: the EC2, after the stack is up (Postgres + n8n Running).
set -euo pipefail

if [ -t 1 ]; then BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""; fi

NS=graphrag
CLUSTER=graphrag-postgres-n8n

OUTFILE="$HOME/workflows-pg-dumpall-$(date +%F).sql"

echo "${BOLD}Creating workflow DB dump -> $(basename "$OUTFILE")...${RESET}"

echo "  waiting for the n8n Postgres primary to be Ready..."
kubectl -n "$NS" wait --for=condition=Ready pod -l "cnpg.io/cluster=$CLUSTER,role=primary" --timeout=300s

PGPOD=$(kubectl -n "$NS" get pod -l "cnpg.io/cluster=$CLUSTER,role=primary" -o jsonpath='{.items[0].metadata.name}')
PGPW=$(kubectl -n "$NS" get secret n8n-postgres-superuser -o jsonpath='{.data.password}' | base64 -d)

echo "  sanity counts (source):"
kubectl -n "$NS" exec "$PGPOD" -- env PGPASSWORD="$PGPW" psql -U postgres -d n8n \
    -c 'select count(*) as workflows   from workflow_entity;' \
    -c 'select count(*) as credentials from credentials_entity;' 2>/dev/null || true

echo "  running pg_dumpall (no --clean; restore-workflows-dumpall.sh drops the DB first)..."
kubectl -n "$NS" exec "$PGPOD" -- env PGPASSWORD="$PGPW" \
    pg_dumpall -U postgres > "$OUTFILE"

LINES=$(wc -l < "$OUTFILE")
SIZE=$(du -sh "$OUTFILE" | cut -f1)
echo "${GREEN}create-workflows-dumpall: done.${RESET}  $OUTFILE  ($SIZE, ${LINES} lines)"
