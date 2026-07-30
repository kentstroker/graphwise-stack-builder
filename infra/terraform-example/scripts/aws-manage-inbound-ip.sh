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

# ---- scratch / bookkeeping ----
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gw-sg-ip.XXXXXX")"
FAILURES="$SCRATCH/failures.log"; : > "$FAILURES"
STACKS_TSV="$SCRATCH/stacks.tsv"; : > "$STACKS_TSV"
trap 'rm -rf "$SCRATCH"' EXIT

# resolve regions: --region flags win; else the profile's configured region.
resolve_regions() {
  [ "${#REGIONS[@]}" -gt 0 ] && return 0
  local r
  r="$(aws --profile "$PROFILE" configure get region 2>/dev/null || true)"
  [ -n "$r" ] || r="$("${AWS[@]}" configure get region 2>/dev/null || true)"
  [ -n "$r" ] || { echo "ERROR: no region. Pass --region R or set one in the profile." >&2; exit 1; }
  REGIONS=("$r")
}

# discover Graphwise stack SGs into STACKS_TSV + cache each SG JSON.
DESC_MARKER="Graphwise Stack KIND demo"
discover_stacks() {
  local region sgs
  for region in "${REGIONS[@]}"; do
    sgs="$("${AWS[@]}" ec2 describe-security-groups --region "$region" \
            --filters Name=tag:ManagedBy,Values=terraform 2>/dev/null || echo '{}')"
    # keep only SGs whose Description starts with the marker; emit id + friendly name
    printf '%s' "$sgs" | jq -c --arg m "$DESC_MARKER" '
      .SecurityGroups[]? | select((.Description // "") | startswith($m))' \
    | while IFS= read -r sg; do
        local sid sname
        sid="$(printf '%s' "$sg" | jq -r '.GroupId')"
        sname="$(printf '%s' "$sg" | jq -r '(.Tags[]? | select(.Key=="Subdomain") | .Value) // .GroupName')"
        printf '%s' "$sg" > "$SCRATCH/${sid}.json"
        printf '%s\t%s\t%s\n' "$sname" "$sid" "$region" >> "$STACKS_TSV"
      done
  done
}

# print each SG's ingress rules. CIDR sources shown plainly; prefix-list/0.0.0.0
# sources annotated as untouched.
print_inventory() {
  echo
  echo "Discovered stacks (regions: ${REGIONS[*]}):"
  echo
  if [ ! -s "$STACKS_TSV" ]; then
    echo "  (none found — no SG with description starting \"$DESC_MARKER\")"
    return 0
  fi
  local name sid region
  while IFS=$'\t' read -r name sid region; do
    printf '  stack: %-16s %s   %s\n' "$name" "$sid" "$region"
    jq -r '
      .IpPermissions[]?
      | (if .FromPort == null then "all" else (.FromPort|tostring) end) as $p
      | (.IpProtocol) as $proto
      | ( [ .IpRanges[]?     | "\(.CidrIp)\t\(.Description // "")" ]
        + [ .Ipv6Ranges[]?   | "\(.CidrIpv6)\t\(.Description // "")" ]
        + [ .PrefixListIds[]? | "\(.PrefixListId) (prefix list — untouched)\t" ]
        )[]
      | "      \($p)/\($proto)\t\(.)"
    ' "$SCRATCH/${sid}.json" \
    | while IFS=$'\t' read -r portproto src desc; do
        printf '      %-12s %-22s %s\n' "$portproto" "$src" "${desc:+\"$desc\"}"
      done
    echo
  done < "$STACKS_TSV"
}

# emit proto/from/to/desc for each ingress rule whose CidrIp == $2 on SG $1
rules_with_cidr() {  # $1=sid  $2=cidr
  jq -r --arg c "$2" '
    .IpPermissions[]?
    | . as $perm
    | .IpRanges[]? | select(.CidrIp == $c)
    | [ $perm.IpProtocol,
        ($perm.FromPort // "" | tostring),
        ($perm.ToPort   // "" | tostring),
        (.Description // "") ] | @tsv
  ' "$SCRATCH/${1}.json"
}

# build the --ip-permissions JSON for a single (proto,from,to,cidr,desc) rule
_ip_perms_json() {  # $1=proto $2=from $3=to $4=cidr $5=desc
  jq -cn --arg proto "$1" --arg from "$2" --arg to "$3" --arg cidr "$4" --arg desc "$5" '
    { IpProtocol: $proto,
      FromPort:  ($from|tonumber),
      ToPort:    ($to|tonumber),
      IpRanges:  [ ( {CidrIp:$cidr} + (if $desc=="" then {} else {Description:$desc} end) ) ] }
    | [ . ]'
}

authorize_rule() {  # $1=sid $2=proto $3=from $4=to $5=cidr $6=desc
  local sid="$1" perms; perms="$(_ip_perms_json "$2" "$3" "$4" "$5" "$6")"
  if [ "$APPLY" -eq 0 ]; then
    echo "   would ADD    $sid  $3/$2  $5  ${6:+\"$6\"}"
    return 0
  fi
  local out
  if out="$("${AWS[@]}" ec2 authorize-security-group-ingress --group-id "$sid" --ip-permissions "$perms" 2>&1)"; then
    echo "   added:   $sid  $3/$2  $5"
  elif printf '%s' "$out" | grep -q 'InvalidPermission.Duplicate'; then
    echo "   present: $sid  $3/$2  $5 (already authorized)"
  else
    echo "   ! FAILED add $sid $3/$2 $5 -> $out" >&2
    echo "authorize $sid $3/$2 $5 $out" >> "$FAILURES"
  fi
}

revoke_rule() {  # $1=sid $2=proto $3=from $4=to $5=cidr
  local sid="$1" perms; perms="$(_ip_perms_json "$2" "$3" "$4" "$5" "")"
  if [ "$APPLY" -eq 0 ]; then
    echo "   would REMOVE $sid  $3/$2  $5"
    return 0
  fi
  local out
  if out="$("${AWS[@]}" ec2 revoke-security-group-ingress --group-id "$sid" --ip-permissions "$perms" 2>&1)"; then
    echo "   removed: $sid  $3/$2  $5"
  elif printf '%s' "$out" | grep -q 'InvalidPermission.NotFound'; then
    echo "   absent:  $sid  $3/$2  $5 (nothing to revoke)"
  else
    echo "   ! FAILED remove $sid $3/$2 $5 -> $out" >&2
    echo "revoke $sid $3/$2 $5 $out" >> "$FAILURES"
  fi
}

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

# =========================== main ==========================================
resolve_regions
discover_stacks
print_inventory
