#!/usr/bin/env bash
# azure-vm-power.sh -- park and resume a Graphwise Stack Azure VM safely.
#
#   ./scripts/azure-vm-power.sh status
#   ./scripts/azure-vm-power.sh deallocate [--yes] [--skip-quiesce]
#   ./scripts/azure-vm-power.sh start      [--yes]
#
# WHY THIS SCRIPT EXISTS AT ALL
# -----------------------------
# It wraps two `az` commands, and that wrapping is the entire point: Azure
# has a stop/deallocate distinction that AWS does not, and getting it wrong
# is silently expensive.
#
#   AWS:   `aws ec2 stop-instances`  -> compute meter stops. Done.
#   Azure: `az vm stop`              -> PowerState/stopped.
#                                       *** COMPUTE STILL BILLS ***
#          `sudo shutdown -h now`    -> PowerState/stopped. Same trap.
#          `az vm deallocate`        -> PowerState/deallocated.
#                                       Hardware released, meter stops.
#
# A teammate carrying over the AWS habit ("just shut it down from inside")
# pays full price for an idle 8-vCPU / 64 GiB box indefinitely, and nothing
# in the Portal shouts about it -- both states just read "Stopped" at a
# glance. So: this script only ever deallocates, and `status` prints the
# raw power state so you can confirm which one you are actually in.
#
# Managed disks and the Static/Standard public IP both survive deallocation,
# so the stack comes back on the same address with all PVCs intact.
#
# bash 3.2 compatible (macOS built-in bash).

set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RESET=$(printf '\033[0m')
    GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); RED=$(printf '\033[31m')
else
    BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""; RED=""
fi

die() { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

ACTION="${1:-}"
shift || true

ASSUME_YES=0
SKIP_QUIESCE=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y)       ASSUME_YES=1 ;;
        --skip-quiesce) SKIP_QUIESCE=1 ;;
        -h|--help)      usage 0 ;;
        *)              die "unknown flag: $arg" ;;
    esac
done

case "$ACTION" in
    status|start|deallocate) ;;
    -h|--help|"")            usage 0 ;;
    *)                       die "unknown action: $ACTION (expected status|start|deallocate)" ;;
esac

command -v az >/dev/null 2>&1 || die "az CLI not found -- brew install azure-cli"
az account show >/dev/null 2>&1 || die "az not authenticated -- run: az login"

# ---------------------------------------------------------------------------
# Resolve the VM's ARM resource ID from Terraform state.
# ---------------------------------------------------------------------------
# `terraform output` is the source of truth -- it cannot drift from what was
# actually deployed the way a hand-maintained config file can. Requires the
# state to be present, which it is whenever you are in the module folder.
resolve_vm_id() {
    command -v terraform >/dev/null 2>&1 || die "terraform not found -- needed to resolve the VM id"
    ( cd "$MODULE_DIR" && terraform output -raw vm_id 2>/dev/null ) || true
}

VM_ID="${GRAPHWISE_AZURE_VM_ID:-$(resolve_vm_id)}"
[ -n "$VM_ID" ] || die "could not resolve the VM id.
  Run this from a module folder with Terraform state present, or set it
  explicitly:  export GRAPHWISE_AZURE_VM_ID=\$(az vm show -g <rg> -n <vm> --query id -o tsv)"

power_state() {
    az vm get-instance-view --ids "$VM_ID" \
        --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" \
        -o tsv 2>/dev/null || true
}

confirm() {  # confirm <prompt>
    [ "$ASSUME_YES" -eq 1 ] && return 0
    printf '%s [y/N] ' "$1"
    read -r reply
    case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

STATE="$(power_state)"
printf '%sVM:%s    %s\n' "$BOLD" "$RESET" "${VM_ID##*/}"
printf '%sState:%s  %s\n' "$BOLD" "$RESET" "${STATE:-<unknown>}"

case "$ACTION" in

    status)
        case "$STATE" in
            *deallocated*)
                printf '\n  %s✓%s Deallocated -- compute meter is STOPPED.\n' "$GREEN" "$RESET"
                printf '    %sYou still pay for the managed disk and the static public IP.%s\n' "$DIM" "$RESET"
                ;;
            *running*)
                printf '\n  %s•%s Running -- billing normally.\n' "$GREEN" "$RESET"
                ;;
            *stopped*)
                printf '\n  %s!! STOPPED BUT NOT DEALLOCATED -- YOU ARE STILL PAYING FOR COMPUTE.%s\n' "$RED$BOLD" "$RESET"
                printf '  %sThis is the Azure trap the AWS path does not have. Fix it now:%s\n' "$YELLOW" "$RESET"
                printf '    ./scripts/azure-vm-power.sh deallocate\n'
                ;;
            *)
                printf '\n  %s?%s Unrecognised power state.\n' "$YELLOW" "$RESET"
                ;;
        esac
        ;;

    deallocate)
        case "$STATE" in
            *deallocated*)
                printf '\n  %s✓%s Already deallocated -- nothing to do.\n' "$GREEN" "$RESET"
                exit 0
                ;;
        esac

        # Quiesce first. cluster-stop.sh scales the graphwise/graphrag
        # workloads to zero and records their prior replica counts in the
        # graphwise.ai/replicas-before-stop annotation, which cluster-start.sh
        # (auto-invoked by cluster-resume.sh on the next boot) reads back.
        # Skipping it is survivable -- the pods just get hard-stopped -- but
        # a clean scale-down avoids Postgres/GraphDB recovery on restart.
        if [ "$SKIP_QUIESCE" -eq 0 ]; then
            printf '\n%sBefore deallocating, quiesce the workloads:%s\n' "$BOLD" "$RESET"
            printf '    ssh -i $GRAPHWISE_KEY $GRAPHWISE_USER@$GRAPHWISE_HOST "~/gsb/scripts/cluster-stop.sh"\n'
            printf '  %s(Re-run with --skip-quiesce once you have done this, or to skip it.)%s\n' "$DIM" "$RESET"
            confirm "Have you quiesced the cluster (or do you want to proceed anyway)?" \
                || { printf 'Aborted.\n'; exit 1; }
        fi

        confirm "Deallocate the VM now? This stops the compute meter." \
            || { printf 'Aborted.\n'; exit 1; }

        printf '\nDeallocating (this takes ~1-2 minutes)...\n'
        az vm deallocate --ids "$VM_ID"
        printf '\n  %s✓%s New state: %s\n' "$GREEN" "$RESET" "$(power_state)"
        printf '    %sDisks and the static public IP are retained -- resume with: %s start%s\n' \
            "$DIM" "${BASH_SOURCE[0]##*/}" "$RESET"
        ;;

    start)
        case "$STATE" in
            *running*)
                printf '\n  %s✓%s Already running -- nothing to do.\n' "$GREEN" "$RESET"
                exit 0
                ;;
        esac

        confirm "Start the VM now? Compute billing resumes." \
            || { printf 'Aborted.\n'; exit 1; }

        printf '\nStarting (this takes ~1-2 minutes)...\n'
        az vm start --ids "$VM_ID"
        printf '\n  %s✓%s New state: %s\n' "$GREEN" "$RESET" "$(power_state)"
        cat <<'NEXT'

  The graphwise-cluster-resume.service systemd unit restarts the KIND
  containers and calls cluster-start.sh automatically -- no manual step.
  Give it a couple of minutes, then check from the VM:

      systemctl status graphwise-cluster-resume
      kubectl get pods -A

  Reminder: PoolParty's extraction index does not survive a stop/start.
  cluster-resume.sh runs poolparty-extractor-guard.sh for you, but if the
  GraphRAG Concept Enricher misbehaves, run it by hand:

      ~/gsb/scripts/poolparty-extractor-guard.sh
NEXT
        ;;
esac
