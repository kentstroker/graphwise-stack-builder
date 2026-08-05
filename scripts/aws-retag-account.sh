#!/usr/bin/env bash
#
# aws-retag-account.sh — enforce the three operator-attribution tags on every
# taggable resource in the AWS account, across all enabled regions.
#
# Canonical tags (exact spelling / case — AWS tag keys are case-sensitive):
#     ownerOrganizationId = gws
#     project             = demo
#     ownerOUid           = pse
#
# What it does, per resource:
#   1. If any canonical key is missing or holds the wrong value, (over)write all
#      three. Overwrite fixes historically swapped values (project=pse /
#      ownerOUid=demo) automatically.
#   2. Remove any stale key that matches a canonical key CASE-INSENSITIVELY but
#      isn't the exact spelling (e.g. the old capital-I "ownerOUId"), so you
#      don't end up with duplicate keys.
#   3. Skip anything already fully compliant (no API write) — so re-runs and the
#      dry-run report show only genuine deltas.
#
# Engine: Resource Groups Tagging API (spans services). Route53 hosted zones are
# not covered by RGTA, so they get a dedicated supplementary pass. IAM is out of
# scope for v1 and is logged as skipped (never silently dropped).
#
# DRY-RUN BY DEFAULT. Pass --apply to actually write.
#
# Usage:
#   scripts/aws-retag-account.sh [--apply] [--profile NAME] [--region R]...
#                                [--yes] [-h|--help]
#
#   --apply          Make changes. Without it, only report what would change.
#   --profile NAME   AWS CLI profile (default: $AWS_PROFILE or "default").
#   --region R       Limit to region R (repeatable). Default: all enabled regions.
#   --exclude-service SVC  Skip resources whose ARN service is SVC (repeatable),
#                    e.g. --exclude-service iam --exclude-service route53.
#                    Excluding "route53" also skips the hosted-zone pass.
#   --yes            Skip the interactive confirmation prompt under --apply.
#   -h, --help       This help.
#
# Requires: aws CLI v2, jq. Bash 3.2 compatible (macOS built-in).
#
set -euo pipefail

# ---- canonical tags (parallel arrays; bash 3.2 has no associative arrays) ----
CANON_KEYS=(ownerOrganizationId project ownerOUid)
CANON_VALS=(gws demo pse)

# canon as JSON object for jq, and the tag-resources shorthand string
CANON_JSON='{"ownerOrganizationId":"gws","project":"demo","ownerOUid":"pse"}'
TAGS_SHORTHAND="ownerOrganizationId=gws,project=demo,ownerOUid=pse"

# ---- defaults ----
APPLY=0
ASSUME_YES=0
PROFILE="${AWS_PROFILE:-default}"
REGIONS=()
EXCLUDE_SVCS=()   # ARN service prefixes to skip entirely, e.g. iam, route53

usage() { sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; }

# ---- arg parse ----
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --region)  REGIONS+=("${2:?--region needs a value}"); shift 2 ;;
    --exclude-service) EXCLUDE_SVCS+=("${2:?--exclude-service needs a value}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# JSON array of excluded services for jq; and a flag for the Route53 pass
EXCLUDE_JSON="$(printf '%s\n' ${EXCLUDE_SVCS[@]+"${EXCLUDE_SVCS[@]}"} | jq -R . | jq -cs .)"
SKIP_ROUTE53=0
for s in ${EXCLUDE_SVCS[@]+"${EXCLUDE_SVCS[@]}"}; do [ "$s" = "route53" ] && SKIP_ROUTE53=1; done

# ---- dependency checks ----
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq not found" >&2; exit 1; }

AWS=(aws --profile "$PROFILE" --output json)

# ---- identity / account guard ----
IDENT_JSON="$("${AWS[@]}" sts get-caller-identity 2>/dev/null || true)"
[ -n "$IDENT_JSON" ] || { echo "ERROR: could not resolve AWS identity with profile '$PROFILE'. Check credentials." >&2; exit 1; }
ACCOUNT_ID="$(printf '%s' "$IDENT_JSON" | jq -r '.Account')"
CALLER_ARN="$(printf '%s' "$IDENT_JSON" | jq -r '.Arn')"

echo "============================================================"
echo " AWS account-wide retag"
echo "   account : $ACCOUNT_ID"
echo "   caller  : $CALLER_ARN"
echo "   profile : $PROFILE"
echo "   tags    : ownerOrganizationId=gws project=demo ownerOUid=pse"
echo "   mode    : $([ "$APPLY" -eq 1 ] && echo 'APPLY (writes changes)' || echo 'DRY-RUN (no changes)')"
echo "============================================================"

# ---- scratch / bookkeeping ----
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/aws-retag.XXXXXX")"
FAILURES="$SCRATCH/failures.log"           # any non-empty => exit non-zero
: > "$FAILURES"
trap 'rm -rf "$SCRATCH"' EXIT

# running totals
T_SCANNED=0; T_COMPLIANT=0; T_TOTAG=0; T_STALE=0

# jq program: emit "arn<TAB>needsTag(0|1)<TAB>staleKeysCSV" for resources that
# need a tag write and/or have stale-variant keys. Skips fully-compliant ones.
JQ_CLASSIFY='
  ($canon | keys_unsorted)                       as $ck
| ($canon | keys_unsorted | map(ascii_downcase)) as $ckl
| .ResourceTagMappingList[]
| .ResourceARN as $arn
| ($arn | split(":")[2]) as $svc
| select( ($exclude | index($svc)) == null )     # skip excluded ARN services (e.g. iam, route53)
| (reduce .Tags[] as $t ({}; . + {($t.Key): $t.Value})) as $tags
| ( any($ck[]; . as $k | ($tags[$k] // null) != ($canon[$k]) ) ) as $needs
| ( [ $tags | keys[] | . as $k
      | select( ($ckl | index($k | ascii_downcase)) != null   # matches a canon key case-insensitively
                and ($ck | index($k)) == null ) ]              # ...but is not the exact canonical spelling
  ) as $stale
| select($needs or ($stale|length > 0))
| [ $arn, (if $needs then "1" else "0" end), ($stale | join(",")) ]
| @tsv
'

# ---- helper: batch tag-resources (up to 20 ARNs/call) ----
do_tag_batch() {  # $1=region ("global" for none)  $2..=ARNs
  local region="$1"; shift
  [ $# -gt 0 ] || return 0
  local -a args=(resourcegroupstaggingapi tag-resources
                 --resource-arn-list "$@" --tags "$TAGS_SHORTHAND")
  [ "$region" != "global" ] && args+=(--region "$region")
  local out
  out="$("${AWS[@]}" "${args[@]}" 2>&1)" || { echo "$out" >> "$FAILURES"; echo "   ! tag-resources call failed: $out" >&2; return 0; }
  printf '%s' "$out" | jq -r '.FailedResourcesMap // {} | to_entries[] | "\(.key)\t\(.value.ErrorCode): \(.value.ErrorMessage)"' \
    | while IFS=$'\t' read -r farn fmsg; do
        echo "   ! FAILED tag $farn -> $fmsg" >&2
        echo "tag $farn $fmsg" >> "$FAILURES"
      done
}

# ---- helper: batch untag-resources (up to 20 ARNs/call), keys given ----
do_untag_batch() {  # $1=region  $2=comma-separated keys  $3..=ARNs
  local region="$1" keycsv="$2"; shift 2
  [ $# -gt 0 ] || return 0
  local -a keys=()
  local IFS=,; for k in $keycsv; do [ -n "$k" ] && keys+=("$k"); done; unset IFS
  [ "${#keys[@]}" -gt 0 ] || return 0
  local -a args=(resourcegroupstaggingapi untag-resources
                 --resource-arn-list "$@" --tag-keys "${keys[@]}")
  [ "$region" != "global" ] && args+=(--region "$region")
  local out
  out="$("${AWS[@]}" "${args[@]}" 2>&1)" || { echo "$out" >> "$FAILURES"; echo "   ! untag-resources call failed: $out" >&2; return 0; }
  printf '%s' "$out" | jq -r '.FailedResourcesMap // {} | to_entries[] | "\(.key)\t\(.value.ErrorCode): \(.value.ErrorMessage)"' \
    | while IFS=$'\t' read -r farn fmsg; do
        echo "   ! FAILED untag $farn -> $fmsg" >&2
        echo "untag $farn $fmsg" >> "$FAILURES"
      done
}

# ---- process one region's classified deltas (tag file + stale file) ----
apply_region_writes() {  # $1=region  $2=tagfile(arn/line)  $3=stalefile(csv\tarn)
  local region="$1" tagfile="$2" stalefile="$3"

  # tag writes: batch 20 ARNs sharing the same canonical tag set
  if [ -s "$tagfile" ]; then
    local -a batch=()
    while IFS= read -r arn; do
      [ -n "$arn" ] || continue
      batch+=("$arn")
      if [ "${#batch[@]}" -ge 20 ]; then
        do_tag_batch "$region" "${batch[@]}"; batch=()
      fi
    done < "$tagfile"
    [ "${#batch[@]}" -gt 0 ] && do_tag_batch "$region" "${batch[@]}"
  fi

  # stale-key removals: group by identical key-set, batch 20 ARNs each
  if [ -s "$stalefile" ]; then
    local cur="" ; local -a sbatch=()
    # sort so identical csv key-sets are adjacent
    while IFS=$'\t' read -r csv arn; do
      [ -n "$arn" ] || continue
      if [ "$csv" != "$cur" ] || [ "${#sbatch[@]}" -ge 20 ]; then
        [ "${#sbatch[@]}" -gt 0 ] && do_untag_batch "$region" "$cur" "${sbatch[@]}"
        sbatch=(); cur="$csv"
      fi
      sbatch+=("$arn")
    done < <(sort "$stalefile")
    [ "${#sbatch[@]}" -gt 0 ] && do_untag_batch "$region" "$cur" "${sbatch[@]}"
  fi
}

# ---- confirmation gate for --apply ----
if [ "$APPLY" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; then
  printf '\nAbout to WRITE tags across account %s. Type the account id to proceed: ' "$ACCOUNT_ID"
  read -r reply < /dev/tty || reply=""
  [ "$reply" = "$ACCOUNT_ID" ] || { echo "Aborted."; exit 1; }
fi

# ---- resolve regions ----
if [ "${#REGIONS[@]}" -eq 0 ]; then
  echo; echo "Discovering enabled regions..."
  # shellcheck disable=SC2207
  REGIONS=($("${AWS[@]}" ec2 describe-regions \
      --filters Name=opt-in-status,Values=opt-in-not-required,opted-in \
      --query 'Regions[].RegionName' --output text))
fi
echo "Regions: ${REGIONS[*]}"

# =========================== regional sweeps ===============================
for region in "${REGIONS[@]}"; do
  echo; echo "── region: $region ──────────────────────────────────────────"
  res_json="$("${AWS[@]}" resourcegroupstaggingapi get-resources --region "$region" 2>/dev/null || echo '{}')"
  total="$(printf '%s' "$res_json" | jq '.ResourceTagMappingList | length')"
  T_SCANNED=$((T_SCANNED + total))

  tagfile="$SCRATCH/${region}.tag"; stalefile="$SCRATCH/${region}.stale"
  : > "$tagfile"; : > "$stalefile"
  r_totag=0; r_stale=0

  while IFS=$'\t' read -r arn needs stale; do
    [ -n "$arn" ] || continue
    if [ "$needs" = "1" ]; then echo "$arn" >> "$tagfile"; r_totag=$((r_totag+1)); fi
    if [ -n "$stale" ]; then printf '%s\t%s\n' "$stale" "$arn" >> "$stalefile"; r_stale=$((r_stale+1)); fi
    if [ "$APPLY" -eq 0 ]; then
      echo "   would fix: $arn  [tag=$([ "$needs" = 1 ] && echo yes || echo no) stale='${stale}']"
    fi
  done < <(printf '%s' "$res_json" | jq -r --argjson canon "$CANON_JSON" --argjson exclude "$EXCLUDE_JSON" "$JQ_CLASSIFY")

  # compliant = scanned minus distinct affected ARNs (a resource may need both a
  # tag write and a stale-key removal, so de-dupe across both files)
  affected="$( { cut -f2 "$stalefile" 2>/dev/null; cat "$tagfile" 2>/dev/null; } | sort -u | grep -c . || true )"
  compliant=$((total - affected))
  T_COMPLIANT=$((T_COMPLIANT + compliant))
  T_TOTAG=$((T_TOTAG + r_totag)); T_STALE=$((T_STALE + r_stale))

  echo "   scanned=$total  compliant=$compliant  to-tag=$r_totag  stale-keys-on=$r_stale"

  [ "$APPLY" -eq 1 ] && apply_region_writes "$region" "$tagfile" "$stalefile"
done

# =========================== Route53 pass ==================================
echo; echo "── Route53 hosted zones (global) ────────────────────────────"
if [ "$SKIP_ROUTE53" -eq 1 ]; then
  echo "   SKIPPED (--exclude-service route53)."
else
zones_json="$("${AWS[@]}" route53 list-hosted-zones --output json 2>/dev/null || echo '{}')"
zcount="$(printf '%s' "$zones_json" | jq '.HostedZones | length')"
echo "   hosted zones: $zcount"

printf '%s' "$zones_json" | jq -r '.HostedZones[] | "\(.Id)\t\(.Name)"' | while IFS=$'\t' read -r zid zname; do
  zclean="${zid#/hostedzone/}"
  tags_json="$("${AWS[@]}" route53 list-tags-for-resource --resource-type hostedzone --resource-id "$zclean" --output json 2>/dev/null || echo '{}')"
  # classify with the same jq logic by wrapping into the RGTA shape.
  # ResourceARN is set to a route53-shaped string so the $exclude filter is consistent.
  wrapped="$(printf '%s' "$tags_json" | jq -c --arg id "$zclean" '{ResourceTagMappingList: [ {ResourceARN: ("arn:aws:route53:::hostedzone/"+$id), Tags: (.ResourceTagSet.Tags // [])} ]}')"
  line="$(printf '%s' "$wrapped" | jq -r --argjson canon "$CANON_JSON" --argjson exclude "$EXCLUDE_JSON" "$JQ_CLASSIFY")"
  [ -n "$line" ] || { echo "   compliant: $zname ($zclean)"; continue; }
  needs="$(printf '%s' "$line" | cut -f2)"; stale="$(printf '%s' "$line" | cut -f3)"

  if [ "$APPLY" -eq 0 ]; then
    echo "   would fix: $zname ($zclean)  [tag=$([ "$needs" = 1 ] && echo yes || echo no) stale='${stale}']"
    continue
  fi

  args=(route53 change-tags-for-resource --resource-type hostedzone --resource-id "$zclean")
  [ "$needs" = "1" ] && args+=(--add-tags Key=ownerOrganizationId,Value=gws Key=project,Value=demo Key=ownerOUid,Value=pse)
  if [ -n "$stale" ]; then
    rk=(); IFS=,; for k in $stale; do [ -n "$k" ] && rk+=("$k"); done; unset IFS
    [ "${#rk[@]}" -gt 0 ] && args+=(--remove-tag-keys "${rk[@]}")
  fi
  if out="$("${AWS[@]}" "${args[@]}" 2>&1)"; then
    echo "   fixed: $zname ($zclean)"
  else
    echo "   ! FAILED route53 $zclean -> $out" >&2
    echo "route53 $zclean $out" >> "$FAILURES"
  fi
done
fi

# =========================== IAM (skipped, logged) =========================
echo; echo "── IAM ──────────────────────────────────────────────────────"
echo "   SKIPPED (IAM users/roles/instance-profiles use a separate tag API; handle manually)."

# =========================== summary =======================================
echo
echo "============================================================"
echo " Summary ($([ "$APPLY" -eq 1 ] && echo APPLIED || echo DRY-RUN))"
echo "   RGTA scanned      : $T_SCANNED"
echo "   already compliant : $T_COMPLIANT"
echo "   needed tag write  : $T_TOTAG"
echo "   had stale keys    : $T_STALE"
echo "============================================================"

if [ -s "$FAILURES" ]; then
  echo "COMPLETED WITH FAILURES ($(grep -c . "$FAILURES") resource(s)) — see messages above." >&2
  exit 1
fi

if [ "$APPLY" -eq 0 ] && { [ "$T_TOTAG" -gt 0 ] || [ "$T_STALE" -gt 0 ]; }; then
  echo "Dry-run only. Re-run with --apply to make the changes above."
fi
echo "Done."
