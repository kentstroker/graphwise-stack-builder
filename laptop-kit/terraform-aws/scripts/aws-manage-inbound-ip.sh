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
#   add-https <new/32>              grant new/32 on port 443 (HTTPS) only
#   remove   <cidr/32>              revoke a /32 from every rule carrying it
#   open-public                     grant 0.0.0.0/0 + ::/0 on 443 (HTTPS) ONLY
#   close-public                    revoke every 0.0.0.0/0 + ::/0 ingress rule
#   audit                           inventory + exposure report, then exit
#
# Prefix-list sources (e.g. the manual EC2 Instance Connect port-22 rule) are
# NEVER matched or modified. World sources (0.0.0.0/0, ::/0) are likewise
# invisible to replace/add/add-https/remove -- normalize_cidr rejects a /0 mask,
# so an admin source can never be a world CIDR. World rules are reachable ONLY
# through the dedicated open-public / close-public operations below.
#
# SSH IS NEVER OPENED TO THE WORLD. open-public is structurally incapable of
# emitting anything but tcp/443, and every run audits all discovered SGs for a
# world-open rule covering port 22 -- reporting it loudly and exiting non-zero.
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
#                    Pass "auto" to use this laptop's detected public IP.
#   --open-public    Operation: allow the world on 443 (HTTPS) only.
#   --close-public   Operation: revoke every world (0.0.0.0/0 / ::/0) rule.
#   --audit          Operation: report exposure only; never writes. Exits 1 if
#                    any SG allows the world on SSH.
#   -h, --help       This help.
#
# Requires: aws CLI v2, jq. Bash 3.2 compatible (macOS built-in).
#
set -euo pipefail

usage() { sed -n '2,/^# Requires/p' "$0" | sed 's/^# \{0,1\}//'; }

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
    --open-public)  OP=open_public;  shift ;;
    --close-public) OP=close_public; shift ;;
    --audit)        OP=audit;        shift ;;
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
  if [ "$mask" -eq 0 ]; then return 1; fi   # reject 0.0.0.0/0 as an admin source
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

# ---- world sources -------------------------------------------------------
# Deliberately NOT produced by normalize_cidr: that function rejects a /0 mask
# so replace/add/add-https/remove can never target the world. These two
# constants are used only by op_open_public / op_close_public.
WORLD_V4="0.0.0.0/0"
WORLD_V6="::/0"
HTTPS_PORT=443

# ---- this laptop's public IP --------------------------------------------
# Ported from sync-admin-ip.sh. -4 is load-bearing: an IPv6 answer glued to /32
# is an invalid CIDR that AWS rejects with an opaque error.
is_ipv4() {
  local ip="${1:-}" o1 o2 o3 o4 extra o
  case "$ip" in ""|*[!0-9.]*) return 1 ;; esac
  IFS=. read -r o1 o2 o3 o4 extra <<< "$ip"
  [ -n "${o4:-}" ] || return 1
  [ -z "${extra:-}" ] || return 1
  for o in "$o1" "$o2" "$o3" "$o4"; do
    case "$o" in ''|*[!0-9]*) return 1 ;; esac
    [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
  done
  return 0
}

# A private/loopback/CGNAT answer means a proxy or captive portal intercepted
# the lookup. That CIDR would grant nothing while looking like it worked.
is_public_ipv4() {
  local ip="$1" o1 rest o2
  o1="${ip%%.*}"; rest="${ip#*.}"; o2="${rest%%.*}"
  case "$o1" in
    0|10|127) return 1 ;;
    169) [ "$o2" -eq 254 ] && return 1 ;;
    172) { [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; } && return 1 ;;
    192) [ "$o2" -eq 168 ] && return 1 ;;
    100) { [ "$o2" -ge 64 ] && [ "$o2" -le 127 ]; } && return 1 ;;
  esac
  [ "$o1" -ge 224 ] && return 1
  return 0
}

detect_ip() {
  local url raw
  for url in https://checkip.amazonaws.com https://api.ipify.org https://ifconfig.me/ip; do
    raw="$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" || raw=""
    [ -n "$raw" ] || continue
    is_ipv4 "$raw" || continue
    if ! is_public_ipv4 "$raw"; then
      echo "ERROR: detected $raw, a private/loopback address -- a captive portal or" >&2
      echo "       corporate proxy likely answered. Sign in (or drop the VPN) and retry." >&2
      return 1
    fi
    printf '%s/32' "$raw"
    return 0
  done
  return 1
}

# ---- IP history ----------------------------------------------------------
# The addresses THIS laptop has held. Used only to offer sensible defaults for
# replace/remove -- a CIDR listed here is provably ours, so proposing it for
# retirement is safe even on a stack shared with another PSE.
HISTORY_FILE="${HOME}/.graphwise-stack/laptop-ips"
HISTORY_MAX=20

history_load() {
  [ -f "$HISTORY_FILE" ] || return 0
  grep -v '^[[:space:]]*#' "$HISTORY_FILE" 2>/dev/null | grep -v '^[[:space:]]*$' || true
}

history_add() {  # $1 = cidr
  local cidr="$1" tmp
  [ -n "$cidr" ] || return 0
  history_load | grep -qxF "$cidr" && return 0
  mkdir -p "$(dirname "$HISTORY_FILE")" 2>/dev/null || return 0
  if [ ! -f "$HISTORY_FILE" ]; then
    {
      echo "# Public IPs this laptop has used, oldest first."
      echo "# aws-manage-inbound-ip.sh offers these as defaults when retiring an old IP."
    } > "$HISTORY_FILE" 2>/dev/null || return 0
  fi
  echo "$cidr" >> "$HISTORY_FILE" 2>/dev/null || return 0
  chmod 600 "$HISTORY_FILE" 2>/dev/null || true
  if [ "$(history_load | grep -c . || echo 0)" -gt "$HISTORY_MAX" ]; then
    tmp="${HISTORY_FILE}.tmp.$$"
    {
      grep '^[[:space:]]*#' "$HISTORY_FILE" 2>/dev/null || true
      history_load | tail -n "$HISTORY_MAX"
    } > "$tmp" 2>/dev/null && mv "$tmp" "$HISTORY_FILE" 2>/dev/null
    chmod 600 "$HISTORY_FILE" 2>/dev/null || true
  fi
}

# "--new auto" resolves to this laptop's detected public IP.
if [ "$NEW_CIDR" = "auto" ]; then
  NEW_CIDR="$(detect_ip)" || { echo "ERROR: could not detect this laptop's public IP." >&2; exit 1; }
  echo "Detected public IP: $NEW_CIDR"
fi

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

# emit proto/from/to/desc for each ingress rule whose source == $2 on SG $1.
# Matches IPv4 AND IPv6 sources: the inventory has always surfaced Ipv6Ranges,
# but until now the mutation path could not act on what it displayed, so a
# world-open ::/0 rule was reportable and un-removable.
rules_with_cidr() {  # $1=sid  $2=cidr
  jq -r --arg c "$2" '
    .IpPermissions[]?
    | . as $perm
    | ( [ .IpRanges[]?   | select(.CidrIp   == $c) | (.Description // "") ]
      + [ .Ipv6Ranges[]? | select(.CidrIpv6 == $c) | (.Description // "") ] )[]
    | [ $perm.IpProtocol,
        ($perm.FromPort // "" | tostring),
        ($perm.ToPort   // "" | tostring),
        . ] | @tsv
  ' "$SCRATCH/${1}.json"
}

# build the --ip-permissions JSON for a single (proto,from,to,cidr,desc) rule.
# A cidr containing ":" goes in Ipv6Ranges; protocol -1 ("all traffic") carries
# no port pair, so emitting FromPort/ToPort for it would be rejected by the API.
_ip_perms_json() {  # $1=proto $2=from $3=to $4=cidr $5=desc
  jq -cn --arg proto "$1" --arg from "$2" --arg to "$3" --arg cidr "$4" --arg desc "$5" '
    ( if ($cidr | test(":"))
      then { Ipv6Ranges: [ ( {CidrIpv6:$cidr} + (if $desc=="" then {} else {Description:$desc} end) ) ] }
      else { IpRanges:   [ ( {CidrIp:$cidr}   + (if $desc=="" then {} else {Description:$desc} end) ) ] }
      end ) as $ranges
    | { IpProtocol: $proto }
      + ( if $proto == "-1" or $from == "" or $to == "" then {}
          else { FromPort: ($from|tonumber), ToPort: ($to|tonumber) } end )
      + $ranges
    | [ . ]'
}

# Render a rule's ports for humans. "$from/$proto" is fine for the single-port
# admin rules this script was built on, but close-public surfaces wide ranges
# and protocol -1, where it printed a bare "0/tcp" or "/-1".
_portlabel() {  # $1=proto $2=from $3=to
  if [ "$1" = "-1" ] || [ -z "$2" ] || [ -z "$3" ]; then printf 'all/%s' "$1"
  elif [ "$2" = "$3" ]; then printf '%s/%s' "$2" "$1"
  else printf '%s-%s/%s' "$2" "$3" "$1"; fi
}

authorize_rule() {  # $1=sid $2=proto $3=from $4=to $5=cidr $6=desc
  local sid="$1" perms lbl; perms="$(_ip_perms_json "$2" "$3" "$4" "$5" "$6")"
  lbl="$(_portlabel "$2" "$3" "$4")"
  if [ "$APPLY" -eq 0 ]; then
    echo "   would ADD    $sid  $lbl  $5  ${6:+\"$6\"}"
    return 0
  fi
  local out
  if out="$("${AWS[@]}" ec2 authorize-security-group-ingress --group-id "$sid" --ip-permissions "$perms" 2>&1)"; then
    echo "   added:   $sid  $lbl  $5"
  elif printf '%s' "$out" | grep -q 'InvalidPermission.Duplicate'; then
    echo "   present: $sid  $lbl  $5 (already authorized)"
  else
    echo "   ! FAILED add $sid $lbl $5 -> $out" >&2
    echo "authorize $sid $lbl $5 $out" >> "$FAILURES"
    return 1
  fi
}

revoke_rule() {  # $1=sid $2=proto $3=from $4=to $5=cidr
  local sid="$1" perms lbl; perms="$(_ip_perms_json "$2" "$3" "$4" "$5" "")"
  lbl="$(_portlabel "$2" "$3" "$4")"
  if [ "$APPLY" -eq 0 ]; then
    echo "   would REMOVE $sid  $lbl  $5"
    return 0
  fi
  local out
  if out="$("${AWS[@]}" ec2 revoke-security-group-ingress --group-id "$sid" --ip-permissions "$perms" 2>&1)"; then
    echo "   removed: $sid  $lbl  $5"
  elif printf '%s' "$out" | grep -q 'InvalidPermission.NotFound'; then
    echo "   absent:  $sid  $lbl  $5 (nothing to revoke)"
  else
    echo "   ! FAILED remove $sid $lbl $5 -> $out" >&2
    echo "revoke $sid $lbl $5 $out" >> "$FAILURES"
  fi
}

# ---- exposure audit ------------------------------------------------------
# The guard that actually earns its keep. This script only ever authorizes an
# admin /32, so refusing to CREATE world-open SSH blocks nothing that could
# happen here -- world-open SSH arrives via a Console edit, a hand-run CLI call,
# or a hand-edited SG. So we DETECT it on every run, on the read path.
#
# Matches tcp or -1 ("all traffic") whose port range covers 22, sourced from
# 0.0.0.0/0 or ::/0. A wide range like tcp 0-65535 is caught the same way.
WORLD_SSH_TSV="$SCRATCH/world_ssh.tsv"
WORLD_ANY_TSV="$SCRATCH/world_any.tsv"

scan_world_rules() {
  : > "$WORLD_SSH_TSV"; : > "$WORLD_ANY_TSV"
  [ -s "$STACKS_TSV" ] || return 0
  local name sid region
  while IFS=$'\t' read -r name sid region; do
    jq -r --arg n "$name" --arg s "$sid" --arg r "$region" '
      .IpPermissions[]?
      | . as $perm
      | ( [ .IpRanges[]?   | select(.CidrIp   == "0.0.0.0/0") | "0.0.0.0/0" ]
        + [ .Ipv6Ranges[]? | select(.CidrIpv6 == "::/0")      | "::/0" ] )[]
      | [ $n, $s, $r, $perm.IpProtocol,
          ($perm.FromPort // "" | tostring),
          ($perm.ToPort   // "" | tostring), . ] | @tsv
    ' "$SCRATCH/${sid}.json" >> "$WORLD_ANY_TSV" || true
  done < "$STACKS_TSV"

  # narrow the world set to rules that actually cover SSH
  awk -F'\t' '
    ($4 == "tcp" || $4 == "-1") {
      from = ($5 == "" ? 0     : $5 + 0)
      to   = ($6 == "" ? 65535 : $6 + 0)
      if (from <= 22 && to >= 22) print
    }' "$WORLD_ANY_TSV" > "$WORLD_SSH_TSV" || true
}

report_world_rules() {
  if [ -s "$WORLD_ANY_TSV" ]; then
    echo "World-open ingress (source 0.0.0.0/0 or ::/0):"
    awk -F'\t' '{printf "   %-16s %-12s %s %s-%s  %s\n", $1, $2, $4, ($5==""?"all":$5), ($6==""?"all":$6), $7}' "$WORLD_ANY_TSV"
    echo
  fi
  [ -s "$WORLD_SSH_TSV" ] || return 0
  echo "############################################################"
  echo "# DANGER: SSH (port 22) IS OPEN TO THE ENTIRE INTERNET"
  echo "############################################################"
  awk -F'\t' '{printf "#  stack %-16s %s  %s  proto %s ports %s-%s\n", $1, $2, $7, $4, ($5==""?"all":$5), ($6==""?"all":$6)}' "$WORLD_SSH_TSV"
  echo "#"
  echo "#  This script never creates such a rule -- it arrived out-of-band"
  echo "#  (Console edit, manual CLI call, or a hand-edited security group)."
  echo "#  Remove it now:   $(basename "$0") --close-public --apply"
  echo "############################################################"
  echo
}

SELECTED_TSV="$SCRATCH/selected.tsv"
select_stacks() {
  : > "$SELECTED_TSV"
  while :; do
    printf '\nSelect stacks — "all", a name, or a comma list of names [all]: '
    local reply; read -r reply < /dev/tty || reply="all"
    [ -z "$reply" ] && reply="all"
    if [ "$reply" = "all" ]; then
      cp "$STACKS_TSV" "$SELECTED_TSV"; break
    fi
    : > "$SELECTED_TSV"
    local ok=1 IFS=,
    for want in $reply; do
      want="$(printf '%s' "$want" | tr -d '[:space:]')"
      local match; match="$(awk -F'\t' -v n="$want" '$1==n' "$STACKS_TSV")"
      if [ -z "$match" ]; then echo "   ! no stack named '$want'"; ok=0; else printf '%s\n' "$match" >> "$SELECTED_TSV"; fi
    done
    unset IFS
    [ "$ok" -eq 1 ] && [ -s "$SELECTED_TSV" ] && break
    echo "   try again."
  done
  echo; echo "Selected:"; awk -F'\t' '{printf "   - %s (%s, %s)\n",$1,$2,$3}' "$SELECTED_TSV"
}

ADMIN_PORTS=(22 80 443)
ADMIN_DESCS=("SSH from admin" "HTTP (redirects to 443) - admin only" "HTTPS (every app) - admin only")

# REPLACE old -> new on every rule of every selected SG that carries old.
op_replace() {  # uses OLD_CIDR, NEW_CIDR
  local name sid region
  while IFS=$'\t' read -r name sid region; do
    echo; echo "-- $name ($sid) --"
    local found=0
    while IFS=$'\t' read -r proto from to desc; do
      { [ -n "$from" ] && [ -n "$to" ]; } || continue   # skip all-ports/null
      found=1
      if authorize_rule "$sid" "$proto" "$from" "$to" "$NEW_CIDR" "$desc"; then
        revoke_rule    "$sid" "$proto" "$from" "$to" "$OLD_CIDR"
      fi
    done < <(rules_with_cidr "$sid" "$OLD_CIDR")
    [ "$found" -eq 0 ] && echo "   (no rule carries $OLD_CIDR — nothing to do)"
  done < "$SELECTED_TSV"
  return 0
}

# ADD new on ports 22/80/443 for every selected SG.
op_add() {  # uses NEW_CIDR; $1 = space-separated indices into ADMIN_PORTS (default: all = 22/80/443)
  local idxs="${1:-0 1 2}"
  local name sid region i
  while IFS=$'\t' read -r name sid region; do
    echo; echo "-- $name ($sid) --"
    for i in $idxs; do
      authorize_rule "$sid" tcp "${ADMIN_PORTS[$i]}" "${ADMIN_PORTS[$i]}" "$NEW_CIDR" "${ADMIN_DESCS[$i]}" || true
    done
  done < "$SELECTED_TSV"
}

# REMOVE a cidr from every rule of every selected SG that carries it.
op_remove() {  # uses OLD_CIDR (holds the target cidr for remove)
  local name sid region found
  while IFS=$'\t' read -r name sid region; do
    echo; echo "-- $name ($sid) --"
    found=0
    while IFS=$'\t' read -r proto from to desc; do
      { [ -n "$from" ] && [ -n "$to" ]; } || continue
      found=1
      revoke_rule "$sid" "$proto" "$from" "$to" "$OLD_CIDR"
    done < <(rules_with_cidr "$sid" "$OLD_CIDR")
    [ "$found" -eq 0 ] && echo "   (no rule carries $OLD_CIDR — nothing to do)"
  done < "$SELECTED_TSV"
  return 0
}

# ---- world-facing operations --------------------------------------------
# These are the ONLY paths that may touch a world CIDR. They never call
# normalize_cidr (which rejects a /0 mask), so replace/add/add-https/remove keep
# refusing 0.0.0.0/0 exactly as they always have.

# OPEN the world on HTTPS only. The port list is a literal, not a parameter:
# there is no argument, menu choice, or env var that makes this emit port 22.
op_open_public() {
  local name sid region
  while IFS=$'\t' read -r name sid region; do
    echo; echo "-- $name ($sid) --"
    authorize_rule "$sid" tcp "$HTTPS_PORT" "$HTTPS_PORT" "$WORLD_V4" "HTTPS - PUBLIC (world-open, temporary)" || true
    authorize_rule "$sid" tcp "$HTTPS_PORT" "$HTTPS_PORT" "$WORLD_V6" "HTTPS - PUBLIC (world-open, temporary)" || true
  done < "$SELECTED_TSV"
}

# CLOSE every world rule on the selected SGs, on every port -- including a
# world-open SSH rule this script did not create. Revoking access is the safe
# direction, so this is deliberately broader than what open-public adds.
op_close_public() {
  local name sid region found w
  while IFS=$'\t' read -r name sid region; do
    echo; echo "-- $name ($sid) --"
    found=0
    for w in "$WORLD_V4" "$WORLD_V6"; do
      while IFS=$'\t' read -r proto from to desc; do
        found=1
        revoke_rule "$sid" "$proto" "$from" "$to" "$w"
      done < <(rules_with_cidr "$sid" "$w")
    done
    [ "$found" -eq 0 ] && echo "   (no world-open rule -- nothing to do)"
  done < "$SELECTED_TSV"
  return 0
}

# show addresses this laptop has previously used -- provably ours, so safe to
# suggest for retirement even on a stack shared with another operator.
_hint_history() {
  local h; h="$(history_load)"
  [ -n "$h" ] || return 0
  echo "   previously used by this laptop: $(printf '%s' "$h" | tr '\n' ' ')"
}

# offer the detected public IP as the default so the common case is one Enter.
_prompt_new_cidr() {
  local det=""
  det="$(detect_ip 2>/dev/null || true)"
  if [ -n "$det" ]; then
    printf 'New IPv4 (to allow) [%s]: ' "$det"
    read -r NEW_CIDR < /dev/tty || NEW_CIDR=""
    [ -z "$NEW_CIDR" ] && NEW_CIDR="$det"
  else
    echo "   (could not auto-detect this laptop's public IP)"
    printf 'New IPv4 (to allow): '
    read -r NEW_CIDR < /dev/tty || NEW_CIDR=""
  fi
  NEW_CIDR="$(normalize_cidr "$NEW_CIDR")" || { echo "bad IP"; exit 2; }
}

# pick the operation + gather the IP args it needs (prompts if not on CLI).
prompt_op() {
  if [ -z "$OP" ]; then
    echo; echo "Operation:"
    echo "   1) replace    old/32 -> new/32"
    echo "   2) add        new/32 on 22/80/443"
    echo "   3) remove     a /32 from all rules"
    echo "   4) add-https  new/32 on 443 (HTTPS) only"
    echo "   5) open-public   0.0.0.0/0 + ::/0 on 443 (HTTPS) ONLY  [world-open]"
    echo "   6) close-public  revoke every world rule (incl. any on SSH)"
    echo "   7) audit         exposure report only, no changes"
    echo "   q) quit"
    printf 'Choose [1-7, q]: '; local c; read -r c < /dev/tty || c=""
    case "$c" in
      1) OP=replace ;; 2) OP=add ;; 3) OP=remove ;; 4) OP=add_https ;;
      5) OP=open_public ;; 6) OP=close_public ;; 7) OP=audit ;;
      q|Q) echo "Quit."; exit 0 ;;
      *) echo "aborted."; exit 1 ;;
    esac
  fi
  case "$OP" in
    replace)
      [ -n "$OLD_CIDR" ] || { _hint_history; printf 'Old IPv4 (to retire): '; read -r OLD_CIDR < /dev/tty; OLD_CIDR="$(normalize_cidr "$OLD_CIDR")" || { echo "bad IP"; exit 2; }; }
      [ -n "$NEW_CIDR" ] || { _prompt_new_cidr; }
      ;;
    add|add_https)
      [ -n "$NEW_CIDR" ] || { _prompt_new_cidr; }
      ;;
    remove)
      # remove reuses OLD_CIDR as the target
      [ -n "$OLD_CIDR" ] || { _hint_history; printf 'IPv4 to remove: '; read -r OLD_CIDR < /dev/tty; OLD_CIDR="$(normalize_cidr "$OLD_CIDR")" || { echo "bad IP"; exit 2; }; }
      ;;
    open_public|close_public|audit)
      # world operations take no admin CIDR at all
      ;;
    *) echo "unknown operation: $OP" >&2; exit 2 ;;
  esac
}

# Opening a demo stack to the entire internet is a deliberate act, so it gets
# its own typed confirmation on top of the account-id check -- and --yes does
# NOT waive it. Everything behind 443 (GraphDB, PoolParty, n8n) becomes
# reachable by anyone who learns the hostname.
confirm_world_open() {
  [ "$OP" = "open_public" ] || return 0
  echo
  echo "############################################################"
  echo "# You are about to allow THE ENTIRE INTERNET on port 443."
  echo "############################################################"
  echo "#  Affected stacks:"
  awk -F'\t' '{printf "#    - %s (%s, %s)\n", $1, $2, $3}' "$SELECTED_TSV"
  echo "#"
  echo "#  SSH (22) and HTTP (80) stay restricted -- this adds tcp/443 only."
  echo "#  Every app behind HTTPS becomes reachable by anyone with the hostname."
  echo "#  Close it again with:  $(basename "$0") --close-public --apply"
  echo "############################################################"
  if [ "$APPLY" -eq 0 ]; then
    echo "(dry-run -- nothing will be written)"
    return 0
  fi
  printf "Type 'open to the world' to proceed: "
  local reply; read -r reply < /dev/tty || reply=""
  [ "$reply" = "open to the world" ] || { echo "Aborted."; exit 1; }
}

confirm_apply() {
  [ "$APPLY" -eq 1 ] || return 0
  [ "$ASSUME_YES" -eq 1 ] && return 0
  printf '\nAbout to WRITE SG changes in account %s. Type the account id to proceed: ' "$ACCOUNT_ID"
  local reply; read -r reply < /dev/tty || reply=""
  [ "$reply" = "$ACCOUNT_ID" ] || { echo "Aborted."; exit 1; }
}

tfvars_reminder() {
  # only meaningful when an admin IP was added/replaced
  case "$OP" in replace|add|add_https) : ;; *) return 0 ;; esac
  [ "$APPLY" -eq 1 ] || return 0
  echo
  echo "REMINDER: terraform.tfvars still has the OLD admin_cidr."
  echo "  This SG change is out-of-band (lifecycle ignore_changes=[ingress]); it survives"
  echo "  reboots but NOT a full 'terraform destroy && terraform apply', which recreates the"
  echo "  SG from admin_cidr and would restore the old IP (locking you out again)."
  echo "  Before any destroy/apply, set in terraform.tfvars:   admin_cidr = \"${NEW_CIDR}\""
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

# Exposure audit runs on EVERY invocation, before any operation is chosen --
# you cannot use this tool without being told that SSH is world-open.
scan_world_rules
report_world_rules

[ -s "$STACKS_TSV" ] || { echo "Nothing to manage."; exit 0; }

# --audit / menu option 7: report only, never write. Exit 1 when SSH is exposed
# so the run is usable as a CI or cron check.
if [ "$OP" = "audit" ]; then
  if [ -s "$WORLD_SSH_TSV" ]; then
    echo "AUDIT FAILED: SSH is open to the world on $(wc -l < "$WORLD_SSH_TSV" | tr -d ' ') rule(s)." >&2
    exit 1
  fi
  echo "Audit clean: no world-open SSH rule found."
  exit 0
fi

prompt_op
[ "$OP" = "audit" ] && { [ -s "$WORLD_SSH_TSV" ] && exit 1; exit 0; }
select_stacks
confirm_world_open
confirm_apply

echo; echo "Operation: $OP  ($([ "$APPLY" -eq 1 ] && echo APPLY || echo DRY-RUN))"
case "$OP" in
  replace)      op_replace ;;
  add)          op_add ;;
  add_https)    op_add "2" ;;
  remove)       op_remove ;;
  open_public)  op_open_public ;;
  close_public) op_close_public ;;
esac

# record a successfully-applied admin IP so a later replace/remove can offer it
case "$OP" in
  add|add_https|replace) [ "$APPLY" -eq 1 ] && history_add "$NEW_CIDR" || true ;;
esac

tfvars_reminder

if [ -s "$FAILURES" ]; then
  echo; echo "COMPLETED WITH FAILURES ($(grep -c . "$FAILURES") call(s)) — see messages above." >&2
  exit 1
fi
if [ "$APPLY" -eq 0 ]; then
  echo; echo "Dry-run only. Re-run with --apply to make the changes above."
fi

# A run that leaves SSH open to the world is not a success, whatever else it did.
if [ -s "$WORLD_SSH_TSV" ] && [ "$OP" != "close_public" ]; then
  echo; echo "WARNING: SSH remains open to the world -- see the audit above." >&2
  exit 1
fi
echo "Done."
