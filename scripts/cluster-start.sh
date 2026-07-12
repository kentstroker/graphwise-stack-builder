#!/usr/bin/env bash
# cluster-start.sh — restore application workloads after cluster-stop.sh.
#
# The symmetric partner to cluster-stop.sh. cluster-stop.sh scales every
# Deployment + StatefulSet in the application namespaces (graphwise,
# graphrag) down to 0 and records each workload's prior replica count in
# the annotation
#
#     graphwise.ai/replicas-before-stop=<n>
#
# This script reads that annotation back, scales each workload to the
# recorded count, then removes the annotation.
#
# Why annotation-based (vs "scale everything to 1"):
#   - Restores ONLY what cluster-stop.sh scaled down. A workload that was
#     deliberately disabled (manual `kubectl scale --replicas=0`, no
#     annotation) is left alone.
#   - Survives future replica-count changes — the true count is read
#     back, not hard-coded to 1.
#
# cluster-resume.sh calls this automatically at the end of a resume, so
# the systemd auto-resume path (graphwise-cluster-resume.service) brings
# workloads back hands-off on every EC2 boot. You only run it by hand if
# you scaled down with cluster-stop.sh and brought the cluster back some
# other way.
#
# Run as ec2-user. Idempotent: a workload with no annotation is skipped,
# so re-running is a no-op. Safe when the releases aren't installed (no
# workloads = no-op) or nothing was scaled down.
#
# Usage:
#   ./scripts/cluster-start.sh
#
# Requires a reachable kube API (run cluster-resume.sh first if the
# cluster was down).

set -euo pipefail

APP_NAMESPACES=(graphwise graphrag)
ANNOTATION="graphwise.ai/replicas-before-stop"

if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl not found in PATH." >&2
    exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: kube API not reachable. Run scripts/cluster-resume.sh first." >&2
    exit 1
fi

echo "=== Restoring application workloads ==="

restored_anything=0
for ns in "${APP_NAMESPACES[@]}"; do
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "  namespace '$ns' doesn't exist -- skipping"
        continue
    fi

    while IFS= read -r obj; do
        [[ -z "$obj" ]] && continue
        # jsonpath: the literal dots in the annotation key must be escaped.
        saved=$(kubectl -n "$ns" get "$obj" \
            -o jsonpath='{.metadata.annotations.graphwise\.ai/replicas-before-stop}' \
            2>/dev/null || true)
        [[ -z "$saved" ]] && continue   # not scaled down by cluster-stop.sh

        echo "  $ns/$obj -> replicas=$saved"
        kubectl -n "$ns" scale "$obj" --replicas="$saved" >/dev/null
        # Remove the annotation so a later cluster-stop.sh re-records a
        # fresh count and this stays a no-op until the next stop.
        kubectl -n "$ns" annotate "$obj" "${ANNOTATION}-" >/dev/null 2>&1 || true
        restored_anything=1
    done < <(kubectl -n "$ns" get deploy,statefulset -o name 2>/dev/null)
done

if [[ "$restored_anything" -eq 0 ]]; then
    echo "  nothing to restore (no '$ANNOTATION' annotations found)"
    echo "  -- workloads were never scaled down, or were already restored."
fi

echo
echo "=== Workloads restored ==="
echo "Pods take a few minutes to become Ready. Watch with:"
echo "  kubectl get pods -n graphwise -w"
