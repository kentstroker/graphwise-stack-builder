#!/usr/bin/env bash
#
# Register the seed n8n public-API key in public.user_api_keys.
# The JWT lives in the API_KEYS data table (data_table_user_l7ntmWyu1cIic61W),
# but user_api_keys came back EMPTY (0 rows) -> the key was never registered, so
# every node that calls the n8n public API (token-usage calc, execution loaders)
# would 401. This inserts the matching registration the seed expects.
#
# Idempotent: WHERE NOT EXISTS guards the PK. Ties the key to the first/owner user.

set -euo pipefail

NS=graphrag

PGPOD=$(kubectl -n "$NS" get pod \
  -l cnpg.io/cluster=graphrag-postgres-n8n,role=primary \
  -o jsonpath='{.items[0].metadata.name}')

PGPW=$(kubectl -n "$NS" get secret n8n-postgres-superuser \
  -o jsonpath='{.data.password}' | base64 -d)

kubectl -n "$NS" exec -i "$PGPOD" -- env PGPASSWORD="$PGPW" \
  psql -U postgres -d n8n -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO public.user_api_keys (id, "userId", label, "apiKey", "createdAt", "updatedAt", scopes, audience)
SELECT
  '5xT0Iw4FsDmnAVNh',
  (SELECT id FROM public."user" ORDER BY "createdAt" LIMIT 1),
  'graphwise-graphrag',
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIyZjBhODM5Yy03Njg5LTQ1ZGMtYmE5MS0wNjNlMmM4MDUyOGQiLCJpc3MiOiJuOG4iLCJhdWQiOiJwdWJsaWMtYXBpIiwiaWF0IjoxNzY3OTQ4NzcwfQ.9PqVAcfxLzmR0kEFjRK6junWgfJ09WQiGez_XiVK4LI',
  '2026-01-09 08:52:50.791+00', '2026-01-09 08:52:50.791+00',
  '["credential:create","credential:delete","credential:move","project:create","project:delete","project:list","project:update","securityAudit:generate","sourceControl:pull","tag:create","tag:delete","tag:list","tag:read","tag:update","user:changeRole","user:create","user:delete","user:enforceMfa","user:list","user:read","variable:create","variable:delete","variable:list","variable:update","workflow:create","workflow:delete","workflow:list","workflow:move","workflow:read","workflow:update","workflowTags:update","workflowTags:list","workflow:activate","workflow:deactivate","execution:delete","execution:read","execution:retry","execution:list"]',
  'public-api'
WHERE NOT EXISTS (SELECT 1 FROM public.user_api_keys WHERE id = '5xT0Iw4FsDmnAVNh');
SQL

echo "OK -- api key registered."
