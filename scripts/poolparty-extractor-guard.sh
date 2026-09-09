#!/usr/bin/env bash
# poolparty-extractor-guard.sh — ensure the PoolParty extraction index is
# usable; rebuild it if it is empty.
#
# WHY: PoolParty's extraction model (the concept index the extractor matches
# against) does NOT survive an EC2 stop/start of the stack — every call to
# /extractor/api/extract then fails with:
#     {"success":false,"status":400,
#      "message":"Concept Index is empty for projectId: ..."}
# which silently kills the GraphRAG Concept Enricher and Concept Expansion
# steps on every turn while the rest of the pipeline keeps working (observed
# twice, 2026-07-21 and 2026-07-22, both immediately after a stop/start).
#
# WHAT: (1) wait for PoolParty to answer, (2) canary-probe the extractor,
# (3) if the index is empty (or the probe fails), trigger the index rebuild
#     GET /PoolParty/api/indexbuilder/{projectId}/refresh
# (endpoint verified against the Semantic Connector PPT client source, PP 5.3+,
# 10-minute server-side operation), then (4) poll the canary until concepts
# come back or REBUILD_TIMEOUT expires.
#
# Reaches PoolParty via kubectl port-forward (works on the EC2 host before
# ingress/DNS/TLS are up). Idempotent: healthy index => quick no-op.
#
# Usage:
#   ./scripts/poolparty-extractor-guard.sh              # discover project, guard
#   EXTRACTOR_PROJECT_ID=<uuid> ./scripts/poolparty-extractor-guard.sh
#
# Env overrides:
#   PP_NAMESPACE (graphwise)  PP_SERVICE (graphwise-stack-poolparty)
#   PP_LOCAL_PORT (18081)     PP_AUTH (superadmin:<documented password>)
#   READY_TIMEOUT (600s to wait for PoolParty)  REBUILD_TIMEOUT (900s)
#   CANARY_TEXT ("asthma and allergy care")
#
# Exit 0 = extractor healthy (possibly after a rebuild). Exit 1 = not healthy.
# Called from cluster-resume.sh on every EC2 boot (non-fatal there); also safe
# to run manually any time — e.g. before a benchmark/demo run.

set -euo pipefail

PP_NAMESPACE="${PP_NAMESPACE:-graphwise}"
PP_SERVICE="${PP_SERVICE:-graphwise-stack-poolparty}"
PP_LOCAL_PORT="${PP_LOCAL_PORT:-18081}"
PP_AUTH="${PP_AUTH:-superadmin:corgiDAD#2}"
READY_TIMEOUT="${READY_TIMEOUT:-600}"
REBUILD_TIMEOUT="${REBUILD_TIMEOUT:-900}"
CANARY_TEXT="${CANARY_TEXT:-asthma and allergy care}"
BASE="http://127.0.0.1:${PP_LOCAL_PORT}"

log() { echo "[pp-guard] $*"; }

command -v kubectl >/dev/null 2>&1 || { log "ERROR: kubectl not found"; exit 1; }
command -v curl    >/dev/null 2>&1 || { log "ERROR: curl not found"; exit 1; }

# --- port-forward to the PoolParty service -------------------------------
kubectl -n "$PP_NAMESPACE" port-forward "svc/$PP_SERVICE" \
    "${PP_LOCAL_PORT}:8081" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

# --- wait for PoolParty to answer ----------------------------------------
log "waiting for PoolParty (up to ${READY_TIMEOUT}s)..."
deadline=$(( $(date +%s) + READY_TIMEOUT ))
projects=""
while (( $(date +%s) < deadline )); do
    projects=$(curl -s -u "$PP_AUTH" --max-time 10 \
        "$BASE/extractor/api/projects" 2>/dev/null || true)
    [[ "$projects" == *'"'* ]] && break
    sleep 10
done
if [[ "$projects" != *'"'* ]]; then
    log "ERROR: PoolParty did not answer /extractor/api/projects within ${READY_TIMEOUT}s"
    exit 1
fi

# --- resolve the project uuid --------------------------------------------
PROJECT_ID="${EXTRACTOR_PROJECT_ID:-}"
if [[ -z "$PROJECT_ID" ]]; then
    PROJECT_ID=$(echo "$projects" \
        | grep -oE '"(uuid|id)"[[:space:]]*:[[:space:]]*"[0-9a-f-]{36}"' \
        | head -1 | grep -oE '[0-9a-f-]{36}' || true)
fi
if [[ -z "$PROJECT_ID" ]]; then
    log "ERROR: could not determine extractor project uuid from /extractor/api/projects"
    log "       (set EXTRACTOR_PROJECT_ID explicitly). Response head: ${projects:0:200}"
    exit 1
fi
log "project: $PROJECT_ID"

canary() {
    curl -s -u "$PP_AUTH" --max-time 30 -X POST \
        "$BASE/extractor/api/extract" \
        --data-urlencode "projectId=$PROJECT_ID" \
        --data-urlencode "text=$CANARY_TEXT" \
        --data-urlencode "language=en" 2>/dev/null || true
}

resp=$(canary)
if [[ "$resp" == *'"concepts"'* && "$resp" != *"Concept Index is empty"* ]]; then
    log "OK: extraction index healthy (canary returned concepts)."
    exit 0
fi
log "extractor unhealthy: ${resp:0:160}"

# --- rebuild the extraction index ----------------------------------------
log "triggering index rebuild: GET /PoolParty/api/indexbuilder/$PROJECT_ID/refresh"
rebuild=$(curl -s -u "$PP_AUTH" --max-time "$REBUILD_TIMEOUT" \
    "$BASE/PoolParty/api/indexbuilder/$PROJECT_ID/refresh" || true)
log "rebuild response: ${rebuild:0:200}"
if [[ "$rebuild" == *"404"* || "$rebuild" == *"Not Found"* ]]; then
    log "WARN: indexbuilder endpoint not found on this PoolParty version -"
    log "      rebuild the Extraction Model in the PoolParty UI, and check this"
    log "      installation's API docs for the current indexbuilder path."
fi

# --- poll the canary until concepts return -------------------------------
deadline=$(( $(date +%s) + REBUILD_TIMEOUT ))
while (( $(date +%s) < deadline )); do
    resp=$(canary)
    if [[ "$resp" == *'"concepts"'* && "$resp" != *"Concept Index is empty"* ]]; then
        log "OK: extraction index rebuilt and healthy."
        exit 0
    fi
    sleep 20
done

log "ERROR: extractor still unhealthy after rebuild attempt (${REBUILD_TIMEOUT}s)."
log "       Last canary response: ${resp:0:200}"
exit 1
