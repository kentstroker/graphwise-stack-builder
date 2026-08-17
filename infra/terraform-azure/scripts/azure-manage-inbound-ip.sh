#!/usr/bin/env bash
# azure-manage-inbound-ip.sh -- inventory and fix the admin-CIDR inbound
# rules on every Graphwise Stack NSG in an Azure subscription.
#
#   ./scripts/azure-manage-inbound-ip.sh                          # inventory (dry-run)
#   ./scripts/azure-manage-inbound-ip.sh replace <old/32> <new/32>
#   ./scripts/azure-manage-inbound-ip.sh add     <new/32>
#   ./scripts/azure-manage-inbound-ip.sh remove  <cidr/32>
#
#   Flags: --apply   actually write (default is dry-run)
#          --yes     skip the type-the-subscription-id confirmation
#          --subscription <id>   target a specific subscription
#
# This is the Azure twin of infra/terraform-example/scripts/
# aws-manage-inbound-ip.sh. Same contract, same safety posture:
#
#   - Discovery is by TAG (ManagedBy=terraform + Cloud=azure), not by name
#     glob, so a renamed deployment is still found and an unrelated NSG in
#     the same subscription is never touched.
#   - DRY-RUN BY DEFAULT. Nothing is written without --apply.
#   - --apply is gated on typing the subscription id, so a fat-fingered
#     command in the wrong `az account` context cannot fire.
#   - Never touches a rule whose source is a service tag (Internet,
#     VirtualNetwork, AzureLoadBalancer, ...) or 0.0.0.0/0. Only /32-style
#     literal CIDRs are candidates.
#
# WHY THIS IS NEEDED AT ALL: azurerm_network_security_group carries
# lifecycle { ignore_changes = [security_rule] }, so once a stack is
# provisioned, editing admin_cidr in terraform.tfvars does nothing. Your home
# IP changes; this script is how you follow it. AND THE SAME LOCKOUT TRAP
# APPLIES AS ON AWS: the out-of-band NSG edit does NOT update
# terraform.tfvars, so a later destroy/apply rebuilds the NSG from the STALE
# value and locks you out of the fresh VM. Update terraform.tfvars too.
#
# bash 3.2 compatible (macOS built-in bash).

set -euo pipefail

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RESET=$(printf '\033[0m')
    GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); RED=$(printf '\033[31m')
else
    BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""; RED=""
fi

die() { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

APPLY=0
ASSUME_YES=0
SUBSCRIPTION=""
ACTION="inventory"
ARG1=""
ARG2=""

POSITIONAL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)        APPLY=1 ;;
        --yes|-y)       ASSUME_YES=1 ;;
        --subscription) shift; SUBSCRIPTION="${1:-}" ;;
        -h|--help)      usage 0 ;;
        -*)             die "unknown flag: $1" ;;
        *)              POSITIONAL="$POSITIONAL $1" ;;
    esac
    shift
done

# bash 3.2: no arrays needed here -- word-split the collected positionals.
# shellcheck disable=SC2086
set -- $POSITIONAL
[ $# -ge 1 ] && ACTION="$1"
[ $# -ge 2 ] && ARG1="$2"
[ $# -ge 3 ] && ARG2="$3"

validate_cidr() {  # validate_cidr <value> <label>
    case "$1" in
        0.0.0.0/0) die "$2 must not be 0.0.0.0/0 -- that opens the stack to the internet" ;;
    esac
    printf '%s' "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' \
        || die "$2 must be a literal CIDR like 203.0.113.42/32 (got: '$1')"
}

case "$ACTION" in
    inventory) ;;
    replace)   [ -n "$ARG1" ] && [ -n "$ARG2" ] || die "replace needs <old/32> <new/32>"
               validate_cidr "$ARG1" "old CIDR"; validate_cidr "$ARG2" "new CIDR" ;;
    add)       [ -n "$ARG1" ] || die "add needs <new/32>"
               validate_cidr "$ARG1" "new CIDR" ;;
    remove)    [ -n "$ARG1" ] || die "remove needs <cidr/32>"
               validate_cidr "$ARG1" "CIDR" ;;
    *)         die "unknown action: $ACTION (expected inventory|replace|add|remove)" ;;
esac

command -v az >/dev/null 2>&1 || die "az CLI not found -- brew install azure-cli"
command -v jq >/dev/null 2>&1 || die "jq not found -- brew install jq"
az account show >/dev/null 2>&1 || die "az not authenticated -- run: az login"

AZ_ARGS=""
if [ -n "$SUBSCRIPTION" ]; then
    AZ_ARGS="--subscription $SUBSCRIPTION"
    SUB_ID="$SUBSCRIPTION"
else
    SUB_ID="$(az account show --query id -o tsv)"
fi
SUB_NAME="$(az account show $AZ_ARGS --query name -o tsv 2>/dev/null || echo '<unknown>')"

printf '%sSubscription:%s %s (%s)\n' "$BOLD" "$RESET" "$SUB_NAME" "$SUB_ID"
printf '%sAction:%s       %s%s\n\n' "$BOLD" "$RESET" "$ACTION" \
    "$([ "$APPLY" -eq 1 ] && printf ' (APPLY)' || printf ' (dry-run)')"

# ---------------------------------------------------------------------------
# Discover Graphwise Stack NSGs by tag.
# ---------------------------------------------------------------------------
# The module tags every resource ManagedBy=terraform + Cloud=azure. Requiring
# BOTH keeps this from touching NSGs created by other Terraform in the same
# subscription that happen to carry ManagedBy.
NSG_JSON="$(az network nsg list $AZ_ARGS \
    --query "[?tags.ManagedBy=='terraform' && tags.Cloud=='azure'].{name:name,rg:resourceGroup,sub:tags.Subdomain}" \
    -o json)"

NSG_COUNT="$(printf '%s' "$NSG_JSON" | jq 'length')"
if [ "$NSG_COUNT" -eq 0 ]; then
    printf '%sNo Graphwise Stack NSGs found.%s\n' "$YELLOW" "$RESET"
    printf '  %sLooked for tags ManagedBy=terraform AND Cloud=azure.%s\n' "$DIM" "$RESET"
    exit 0
fi

printf 'Found %s Graphwise Stack NSG(s).\n\n' "$NSG_COUNT"

# ---------------------------------------------------------------------------
# Inventory pass -- always runs, even for mutating actions, so you see the
# current state before anything is written.
# ---------------------------------------------------------------------------
PLANNED=""   # newline-delimited "rg|nsg|rule|newprefix" records

i=0
while [ "$i" -lt "$NSG_COUNT" ]; do
    NSG_NAME="$(printf '%s' "$NSG_JSON" | jq -r ".[$i].name")"
    NSG_RG="$(printf '%s' "$NSG_JSON" | jq -r ".[$i].rg")"
    NSG_SUB="$(printf '%s' "$NSG_JSON" | jq -r ".[$i].sub // \"?\"")"
    i=$((i + 1))

    printf '%s%s%s  %s(rg: %s, subdomain: %s)%s\n' \
        "$BOLD" "$NSG_NAME" "$RESET" "$DIM" "$NSG_RG" "$NSG_SUB" "$RESET"

    RULES_JSON="$(az network nsg rule list $AZ_ARGS --nsg-name "$NSG_NAME" -g "$NSG_RG" \
        --query "[?direction=='Inbound' && access=='Allow'].{name:name,port:destinationPortRange,src:sourceAddressPrefix,srcs:sourceAddressPrefixes,prio:priority}" \
        -o json)"

    RULE_COUNT="$(printf '%s' "$RULES_JSON" | jq 'length')"
    j=0
    while [ "$j" -lt "$RULE_COUNT" ]; do
        R_NAME="$(printf '%s' "$RULES_JSON" | jq -r ".[$j].name")"
        R_PORT="$(printf '%s' "$RULES_JSON" | jq -r ".[$j].port // \"*\"")"
        R_PRIO="$(printf '%s' "$RULES_JSON" | jq -r ".[$j].prio")"
        # A rule uses EITHER sourceAddressPrefix (single) or
        # sourceAddressPrefixes (list). Normalise to a comma-joined string.
        R_SRC="$(printf '%s' "$RULES_JSON" | jq -r ".[$j] | if (.srcs|length) > 0 then (.srcs|join(\",\")) else (.src // \"\") end")"
        j=$((j + 1))

        printf '    %-24s prio %-5s port %-6s src %s\n' "$R_NAME" "$R_PRIO" "$R_PORT" "$R_SRC"

        # Never touch service tags or the world.
        case "$R_SRC" in
            Internet|VirtualNetwork|AzureLoadBalancer|GatewayManager|"*"|"0.0.0.0/0"|"")
                [ "$ACTION" != "inventory" ] && \
                    printf '      %sskipped -- source is a service tag or 0.0.0.0/0%s\n' "$DIM" "$RESET"
                continue
                ;;
        esac

        NEW_SRC=""
        case "$ACTION" in
            replace)
                case ",$R_SRC," in
                    *",$ARG1,"*) NEW_SRC="$(printf '%s' "$R_SRC" | sed "s|$ARG1|$ARG2|g")" ;;
                esac
                ;;
            add)
                case ",$R_SRC," in
                    *",$ARG1,"*) : ;;                       # already present
                    *)           NEW_SRC="$R_SRC,$ARG1" ;;
                esac
                ;;
            remove)
                case ",$R_SRC," in
                    *",$ARG1,"*)
                        NEW_SRC="$(printf '%s' ",$R_SRC," | sed "s|,$ARG1,|,|g" | sed 's|^,||; s|,$||')"
                        [ -n "$NEW_SRC" ] || {
                            printf '      %srefusing -- removing %s would leave the rule with NO source,%s\n' "$YELLOW" "$ARG1" "$RESET"
                            printf '      %swhich would lock you out. Add a replacement first.%s\n' "$YELLOW" "$RESET"
                            continue
                        }
                        ;;
                esac
                ;;
        esac

        if [ -n "$NEW_SRC" ]; then
            printf '      %s->%s %s\n' "$YELLOW" "$RESET" "$NEW_SRC"
            PLANNED="$PLANNED
$NSG_RG|$NSG_NAME|$R_NAME|$NEW_SRC"
        fi
    done
    printf '\n'
done

[ "$ACTION" = "inventory" ] && exit 0

PLANNED_COUNT="$(printf '%s' "$PLANNED" | grep -c '|' || true)"
if [ "$PLANNED_COUNT" -eq 0 ]; then
    printf '%sNothing to change.%s\n' "$GREEN" "$RESET"
    exit 0
fi

printf '%s%s rule change(s) planned.%s\n' "$BOLD" "$PLANNED_COUNT" "$RESET"

if [ "$APPLY" -eq 0 ]; then
    printf '\n%sDRY-RUN -- nothing written. Re-run with --apply to commit.%s\n' "$YELLOW" "$RESET"
    exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
    printf '\nType the subscription id to confirm (%s): ' "$SUB_ID"
    read -r typed
    [ "$typed" = "$SUB_ID" ] || die "subscription id did not match -- aborted, nothing written"
fi

# The update loop must NOT be fed by a pipe: `... | while read` runs the
# loop body in a subshell, so a FAILED=1 set inside it is lost by the time
# the script exits -- the classic silent "reported success, actually failed"
# bug. A temp file carries the failure flag across the subshell boundary,
# which is the bash-3.2-safe way to do this (no `lastpipe`, no process
# substitution needed).
FAIL_FLAG="$(mktemp -t gw-nsg-fail)"
trap 'rm -f "$FAIL_FLAG"' EXIT

printf '%s\n' "$PLANNED" | while IFS='|' read -r p_rg p_nsg p_rule p_src; do
    [ -n "$p_rule" ] || continue
    printf '  updating %s/%s ... ' "$p_nsg" "$p_rule"
    # --source-address-prefixes takes a space-separated list; the collected
    # value is comma-separated, so split it.
    # shellcheck disable=SC2086
    if az network nsg rule update $AZ_ARGS \
            --nsg-name "$p_nsg" -g "$p_rg" --name "$p_rule" \
            --source-address-prefixes $(printf '%s' "$p_src" | tr ',' ' ') \
            -o none 2>/dev/null; then
        printf '%sok%s\n' "$GREEN" "$RESET"
    else
        printf '%sFAILED%s\n' "$RED" "$RESET"
        printf '1' >> "$FAIL_FLAG"
    fi
done

cat <<'TFVARS_REMINDER'

REMINDER -- the NSG is now out of sync with Terraform:
  azurerm_network_security_group carries ignore_changes = [security_rule],
  so this edit will NOT be reverted by the next `terraform apply` -- but it
  also will NOT be recorded. Update admin_cidr in terraform.tfvars to match
  what you just set. A destroy/apply rebuild reads tfvars, and a stale value
  there locks you out of the fresh VM.
TFVARS_REMINDER

if [ -s "$FAIL_FLAG" ]; then
    printf '\n%sOne or more rule updates FAILED -- re-run the inventory to see current state.%s\n' \
        "$RED" "$RESET"
    exit 1
fi
exit 0
