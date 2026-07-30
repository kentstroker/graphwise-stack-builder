#!/usr/bin/env bash
#
# aws-manage-inbound-ip.sh — inventory and manage the admin-CIDR ingress rules
# on every Graphwise demo-stack security group.
#
# Each stack's SG (name "<prefix>-<subdomain>-sg", description starting
# "Graphwise Stack KIND demo …") exposes three admin-restricted ingress rules —
# SSH (22), HTTP (80), HTTPS (443) — all sourced from the operator's home /32.
# Terraform stops managing them after first apply (lifecycle ignore_changes =
# [ingress]), so when your home IP changes you get locked out of every stack.
# This script fixes that live, out-of-band.
#
# It ALWAYS prints an inventory of each stack SG's ingress rules first, then runs
# one operation on interactively-selected stacks:
#   replace  <old/32> -> <new/32>   swap the admin IP on every rule carrying old
#   add      <new/32>               grant new/32 on ports 22/80/443
#   remove   <cidr/32>              revoke a /32 from every rule carrying it
#
# Prefix-list sources (e.g. the manual EC2 Instance Connect port-22 rule) and
# 0.0.0.0/0 are NEVER matched or modified.
#
# DRY-RUN BY DEFAULT. Pass --apply to actually write.
#
# Usage:
#   aws-manage-inbound-ip.sh [--apply] [--yes] [--profile NAME]
#                            [--region R]... [--old A.B.C.D[/32]]
#                            [--new A.B.C.D[/32]] [-h|--help]
#
#   --apply          Make changes. Without it, only report what would change.
#   --yes, -y        Skip the type-the-account-id confirmation under --apply.
#   --profile NAME   AWS CLI profile (default: $AWS_PROFILE or "default").
#   --region R       Region to inventory (repeatable). Default: profile region.
#   --old CIDR       Old IPv4 for a headless replace (bare IP => /32).
#   --new CIDR       New IPv4 for a headless replace/add (bare IP => /32).
#   -h, --help       This help.
#
# Requires: aws CLI v2, jq. Bash 3.2 compatible (macOS built-in).
#
set -euo pipefail

usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- defaults ----
APPLY=0
ASSUME_YES=0
PROFILE="${AWS_PROFILE:-default}"
REGIONS=()
OP=""
OLD_CIDR=""
NEW_CIDR=""

# ---- arg parse ----
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --region)  REGIONS+=("${2:?--region needs a value}"); shift 2 ;;
    --old)     OLD_CIDR="${2:?--old needs a value}"; shift 2 ;;
    --new)     NEW_CIDR="${2:?--new needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# ---- dependency checks ----
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq not found" >&2; exit 1; }

# ---- IPv4 CIDR validation / normalization ----
# echoes canonical CIDR (bare IP -> /32) on success; non-zero + no output on fail.
normalize_cidr() {
  local in="$1" ip mask o1 o2 o3 o4
  case "$in" in
    */*) ip="${in%/*}"; mask="${in#*/}" ;;
    *)   ip="$in";      mask="32" ;;
  esac
  # mask 0..32
  case "$mask" in ''|*[!0-9]*) return 1 ;; esac
  [ "$mask" -ge 0 ] && [ "$mask" -le 32 ] || return 1
  # four dotted octets 0..255
  local IFS=.
  # shellcheck disable=SC2086
  set -- $ip
  [ $# -eq 4 ] || return 1
  for o in "$1" "$2" "$3" "$4"; do
    case "$o" in ''|*[!0-9]*) return 1 ;; esac
    [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
  done
  echo "${ip}/${mask}"
}

if [ -n "$OLD_CIDR" ]; then OLD_CIDR="$(normalize_cidr "$OLD_CIDR")" || { echo "ERROR: --old is not a valid IPv4/CIDR" >&2; exit 2; }; fi
if [ -n "$NEW_CIDR" ]; then NEW_CIDR="$(normalize_cidr "$NEW_CIDR")" || { echo "ERROR: --new is not a valid IPv4/CIDR" >&2; exit 2; }; fi

AWS=(aws --profile "$PROFILE" --output json)

# ---- identity / account guard ----
IDENT_JSON="$("${AWS[@]}" sts get-caller-identity 2>/dev/null || true)"
[ -n "$IDENT_JSON" ] || { echo "ERROR: could not resolve AWS identity with profile '$PROFILE'. Check credentials." >&2; exit 1; }
ACCOUNT_ID="$(printf '%s' "$IDENT_JSON" | jq -r '.Account')"
CALLER_ARN="$(printf '%s' "$IDENT_JSON" | jq -r '.Arn')"

echo "============================================================"
echo " Graphwise stack — SG admin-IP manager"
echo "   account : $ACCOUNT_ID"
echo "   caller  : $CALLER_ARN"
echo "   profile : $PROFILE"
echo "   mode    : $([ "$APPLY" -eq 1 ] && echo 'APPLY (writes changes)' || echo 'DRY-RUN (no changes)')"
echo "============================================================"
