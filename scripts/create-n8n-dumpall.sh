#!/usr/bin/env bash
# create-n8n-dumpall.sh -- snapshot the live n8n workflow database into a
# pg_dumpall plain-SQL file that restore-n8n-dumpall.sh can reload.
#
# Output: $HOME/gsb/infra/terraform-subdomain/files/n8n-pg-dumpall.sql
# (uncompressed; the restore script expects this exact filename)
#
# Run from: the EC2, after the stack is up (Postgres + n8n Running).
set -euo pipefail

if [ -t 1 ]; then BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""; fi

NS=graphrag
CLUSTER=graphrag-postgres-n8n

OUTDIR="$HOME/gsb/infra/terraform-subdomain/files"
OUTFILE="$OUTDIR/n8n-pg-dumpall.sql"

echo "${BOLD}Creating n8n workflow DB dump -> $(basename "$OUTFILE")...${RESET}"

echo "  waiting for the n8n Postgres primary to be Ready..."
kubectl -n "$NS" wait --for=condition=Ready pod -l "cnpg.io/cluster=$CLUSTER,role=primary" --timeout=300s

PGPOD=$(kubectl -n "$NS" get pod -l "cnpg.io/cluster=$CLUSTER,role=primary" -o jsonpath='{.items[0].metadata.name}')
PGPW=$(kubectl -n "$NS" get secret n8n-postgres-superuser -o jsonpath='{.data.password}' | base64 -d)

echo "  sanity counts (source):"
kubectl -n "$NS" exec "$PGPOD" -- env PGPASSWORD="$PGPW" psql -U postgres -d n8n \
    -c 'select count(*) as workflows   from workflow_entity;' \
    -c 'select count(*) as credentials from credentials_entity;' 2>/dev/null || true

mkdir -p "$OUTDIR"

echo "  running pg_dumpall (no --clean; restore-n8n-dumpall.sh drops the DB first)..."
kubectl -n "$NS" exec "$PGPOD" -- env PGPASSWORD="$PGPW" \
    pg_dumpall -U postgres > "$OUTFILE"

LINES=$(wc -l < "$OUTFILE")
SIZE=$(du -sh "$OUTFILE" | cut -f1)
echo "${GREEN}create-n8n-dumpall: done.${RESET}  $OUTFILE  ($SIZE, ${LINES} lines)"
