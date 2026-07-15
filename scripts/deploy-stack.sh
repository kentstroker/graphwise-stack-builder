#!/usr/bin/env bash
# deploy-stack.sh -- one-shot, non-interactive EC2 build for a new stack.
#
# Chains the three steps an operator otherwise runs by hand, in order:
#
#   1. cluster-bootstrap.sh        cluster operators + observability
#                                  (ingress-nginx, cert-manager + LE issuer,
#                                  CNPG, Keycloak operator, metrics-server,
#                                  Dashboard, kube-prometheus-stack), plus the
#                                  wildcard Certificate and Refine/Keycloak
#                                  image pre-loads.
#   2. extract-poolparty-realm.sh  pull + placeholder-substitute the PoolParty
#                                  Keycloak realm JSON, then (it chains)
#                                  install-licenses.sh -> the 3 license Secrets.
#   3. reset-helm.sh --yes         install both Helm releases (umbrella first,
#                                  then graphrag).
#
# The individual scripts are left in place for troubleshooting -- this is
# just the streamlined "happy path" for a typical GA deploy. Run it after
# `terraform apply` + `push-initial.sh` (see NEW-STACK.md).
#
# Usage (on the EC2, from ~/gsb):
#   ./scripts/deploy-stack.sh <subdomain> [base_domain]
#
# base_domain defaults to gw-pse.com (the GA standard) -- reset-helm.sh and
# render-values.sh now default to the same; we still pass it through explicitly.
#
# Idempotent: every step is itself idempotent (helm upgrade --install,
# create-or-replace Secrets). reset-helm is destructive to PVCs by design --
# this script is for a FRESH stack, so that's the intended clean slate.

set -euo pipefail

# ---------------------------------------------------------------------------
# Docker-group self-reexec -- must be first. cloud-init adds ec2-user to the
# docker group, but an SSH session opened before that took effect lacks it.
# Re-exec once under `sg docker` so this script AND its children
# (cluster-bootstrap, extract-poolparty-realm) can all reach the daemon.
# ---------------------------------------------------------------------------
if [[ "${_DOCKER_GROUP_REEXEC:-0}" != "1" ]] && ! docker info >/dev/null 2>&1; then
    echo "Docker socket not accessible -- re-launching under docker group (one-time)..."
    export _DOCKER_GROUP_REEXEC=1
    exec sg docker -c "bash $(realpath "${BASH_SOURCE[0]}") $(printf '%q ' "$@")"
fi

# Inherit cloud-init's env (LE_EMAIL / GRAPHWISE_APEX / ROUTE53_ZONE_ID /
# AWS_REGION) when invoked from a non-login shell.
if [ -r /etc/profile.d/graphwise.sh ]; then
    # shellcheck disable=SC1091
    . /etc/profile.d/graphwise.sh
fi

if [ -t 1 ]; then BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else BOLD=""; GREEN=""; YELLOW=""; RED=""; RESET=""; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SUB="${1:-}"
BASE="${2:-gw-pse.com}"
if [ -z "$SUB" ]; then
    echo "Usage: $0 <subdomain> [base_domain]   (base_domain default: gw-pse.com)" >&2
    exit 2
fi

echo "${BOLD}=== deploy-stack: ${SUB}.${BASE} ===${RESET}"

# ---------------------------------------------------------------------------
# Fail-fast prerequisites. deploy-stack runs non-interactively and step 3
# (reset-helm) is destructive, so catch the common "ran too early" mistakes
# up front rather than 10 minutes into a doomed install.
# ---------------------------------------------------------------------------
fail=0

# (a) KIND cluster reachable.
if ! kubectl cluster-info --context kind-graphwise >/dev/null 2>&1; then
    echo "${RED}✗${RESET} KIND cluster 'kind-graphwise' not reachable. After an EC2 stop/start run scripts/cluster-resume.sh first." >&2
    fail=1
else
    echo "${GREEN}✓${RESET} KIND cluster reachable"
fi

# (b) LE_EMAIL + GRAPHWISE_APEX (cluster-bootstrap needs them).
[ -z "${LE_EMAIL:-}" ]       && { echo "${RED}✗${RESET} LE_EMAIL not set (cloud-init writes it; source /etc/profile.d/graphwise.sh or export it)." >&2; fail=1; } || echo "${GREEN}✓${RESET} LE_EMAIL set"
[ -z "${GRAPHWISE_APEX:-}" ] && { echo "${YELLOW}!${RESET} GRAPHWISE_APEX not set; cluster-bootstrap will re-derive from cloud-init env."; }

# (c) Operator secrets delivered by push-initial.sh.
if [ ! -f "$HOME/graphwise-secrets.yaml" ]; then
    echo "${RED}✗${RESET} ~/graphwise-secrets.yaml missing -- run push-initial.sh from your laptop first (NEW-STACK.md step 6)." >&2
    fail=1
else
    echo "${GREEN}✓${RESET} ~/graphwise-secrets.yaml present"
fi

# (d) License files.master delivered.
miss_lic=0
for f in poolparty.key graphdb.license uv-license.key; do
    [ -f "$REPO_ROOT/files/licenses/$f" ] || { echo "${RED}✗${RESET} missing files/licenses/$f"; miss_lic=1; }
done
if [ "$miss_lic" = "0" ]; then echo "${GREEN}✓${RESET} license files present"; else
    echo "    Push them with push-initial.sh (NEW-STACK.md step 6)." >&2; fail=1
fi

# (e) DNS soft check -- non-fatal (cert-manager retries), but warn loudly.
if command -v dig >/dev/null 2>&1 && [ -n "${GRAPHWISE_APEX:-}" ]; then
    if [ -z "$(dig +short "$GRAPHWISE_APEX" 2>/dev/null)" ]; then
        echo "${YELLOW}!${RESET} ${GRAPHWISE_APEX} does not resolve yet -- the wildcard cert won't go Ready until DNS is live (NEW-STACK.md step 2)."
    else
        echo "${GREEN}✓${RESET} ${GRAPHWISE_APEX} resolves"
    fi
fi

if [ "$fail" != "0" ]; then
    echo "${RED}Aborting: fix the ✗ items above and re-run.${RESET}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 1 -- cluster operators + observability + wildcard cert.
# ---------------------------------------------------------------------------
echo
echo "${BOLD}[1/4] cluster-bootstrap.sh${RESET}"
"$SCRIPT_DIR/cluster-bootstrap.sh"

# ---------------------------------------------------------------------------
# Phase 2 -- PoolParty realm extract (chains install-licenses.sh).
# ---------------------------------------------------------------------------
echo
echo "${BOLD}[2/4] extract-poolparty-realm.sh (+ install-licenses.sh)${RESET}"
"$SCRIPT_DIR/extract-poolparty-realm.sh"

# ---------------------------------------------------------------------------
# Phase 3 -- both Helm releases.
# ---------------------------------------------------------------------------
echo
echo "${BOLD}[3/4] reset-helm.sh --yes ${SUB} ${BASE}${RESET}"
"$SCRIPT_DIR/reset-helm.sh" --yes "$SUB" "$BASE"

# ---------------------------------------------------------------------------
# Phase 4 -- load the shipped n8n workflow DB seed (no-op if no seed present).
# The seed rides the git clone (repo tarball) and is decompressed to $HOME by
# user-data.sh.tpl at cloud-init; this loads it into the fresh n8n Postgres.
# ---------------------------------------------------------------------------
echo
echo "${BOLD}[4/4] restore-workflows-dumpall.sh${RESET}"
"$SCRIPT_DIR/restore-workflows-dumpall.sh"

echo
echo "${BOLD}${GREEN}=== deploy-stack complete: https://${SUB}.${BASE}/ ===${RESET}"
echo "Watch pods:   kubectl get pods -A -w"
echo "Verify URLs:  NEW-STACK.md step 8   |   credentials: CONSOLE-GUIDE.md"
