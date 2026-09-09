#!/usr/bin/env bash
#
# Author:   Kent Stroker
# Created:  2026-08-04
# Modified: 2026-08-04
# Version:  2.3.0
#
# check-tags.sh -- audit (and fix) org compliance tags across the WHOLE account.
#
# Stand-alone laptop helper. It sweeps every enabled region with the Resource
# Groups Tagging API, adds the global resources that API does not cover (IAM
# roles), and checks that every resource carries the org tags:
#
#   ownerOrganizationId = gws
#   project             = demo
#   ownerOUId           = pse
#
# Read-only until you confirm. Non-compliant resources are listed with what is
# missing, wrong (old -> new), or mis-keyed, then a single prompt applies the
# whole set. --list reports EVERY asset and its compliance and never prompts.
#
# CASE-SENSITIVITY -- AWS tag keys are case-sensitive, and this account carries
# BOTH `ownerOUId` and the legacy `ownerOUid`. The keys above are canonical: a
# tag whose key differs only by case is reported as a rekey, and fixing it both
# writes the canonical key AND REMOVES the legacy one. Removal is a destructive
# operation, so it is always counted separately at the confirm prompt.
#
# KNOWN LIMIT -- the Resource Groups Tagging API only returns resources that
# carry at least one tag. A resource that has NEVER been tagged is invisible to
# it (the default VPC, for example). This audit therefore covers every TAGGED
# asset in the account, which is not quite the same as every asset. There is no
# generic API for the latter -- it would need a per-service describe sweep.
#
# AWS-MANAGED RESOURCES -- accounts under AWS Control Tower carry governance
# infrastructure (StackSet-*, aws-controltower-*, the Account Factory VPC,
# Config aggregators, SSO roles). These ARE fixed by default and shown as `aws`
# scope so you can see what you are touching. Two caveats worth knowing:
#   * Control Tower re-stamps its own tags on every baseline refresh, so fixes
#     to those resources drift back.
#   * Some are owned outright by an AWS service (an EventBridge rule with
#     ManagedBy=controltower.amazonaws.com, for instance). AWS ACCEPTS a tag
#     write on those and silently discards it -- the API returns success and
#     nothing changes. The verify pass after each run catches that and reports
#     it rather than printing a false tick.
# Pass --skip-managed to leave all of them alone.
#
# Usage:
#   ./scripts/check-tags.sh [--list] [--region <r>] [--profile <p>] [--skip-managed]
#
#   --list             report EVERY asset and whether it is compliant, then stop.
#                      Never prompts, never writes -- the inventory/report mode.
#   --region <r>       audit ONLY this region (default: every enabled region)
#   --profile <p>      AWS CLI profile (default: $AWS_PROFILE / CLI default)
#   --skip-managed     do NOT touch AWS/Control-Tower-managed resources
#   --include-managed  accepted but now a no-op -- this is the default
#   -h, --help         this help
#
# Requires: aws CLI, jq.
#
# Exit codes:
#   0 -- everything compliant, every fix applied, or --list finished
#   1 -- fixes declined, or one or more tag calls failed
#
# macOS-oriented. Kept bash-3.2 compatible (macOS system bash).

set -uo pipefail

# ── the tag contract ─────────────────────────────────────────────────────────
# Edit here and nowhere else if the org tagging policy changes -- every query
# below is built from these arrays, so adding a key needs no other change.
# These spellings are CANONICAL; any case variant found is rekeyed to these.
EXPECTED_KEYS=(ownerOrganizationId project ownerOUId)
EXPECTED_VALS=(gws                 demo    pse)

# ── colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    RED=$'\033[31m'; CYAN=$'\033[36m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; DIM=""; RESET=""
fi

die()  { printf '%s✗%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }
info() { printf '%s%s%s\n' "$DIM" "$1" "$RESET"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ── args ─────────────────────────────────────────────────────────────────────
REGION_FLAG=""; PROFILE_FLAG=""; SKIP_MANAGED=0; LIST_ONLY=0; SAW_LEGACY_FLAG=0
while [ $# -gt 0 ]; do
    case "$1" in
        --region)          REGION_FLAG="${2:-}"; shift 2 || die "--region needs a value" ;;
        --profile)         PROFILE_FLAG="${2:-}"; shift 2 || die "--profile needs a value" ;;
        --skip-managed)    SKIP_MANAGED=1; shift ;;
        --include-managed) SAW_LEGACY_FLAG=1; shift ;;   # now the default; kept so old commands still run
        --list)            LIST_ONLY=1; shift ;;
        -h|--help)         sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                 die "unknown argument: $1  (try --help)" ;;
    esac
done

HOME_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
[ -z "$HOME_REGION" ] && HOME_REGION="$(aws configure get region 2>/dev/null || true)"
[ -z "$HOME_REGION" ] && HOME_REGION="us-west-2"

AWS_ARGS=()
PROFILE="${PROFILE_FLAG:-${AWS_PROFILE:-}}"
[ -n "$PROFILE" ] && AWS_ARGS+=(--profile "$PROFILE")

# ── preflight ────────────────────────────────────────────────────────────────
command -v aws >/dev/null 2>&1 || die "aws CLI not found -- install it, then: aws configure ${DIM}(region us-west-2)${RESET}"
command -v jq  >/dev/null 2>&1 || die "jq not found -- install it: brew install jq"
ACCOUNT="$(aws sts get-caller-identity "${AWS_ARGS[@]}" --region "$HOME_REGION" \
            --query Account --output text 2>/dev/null)" \
    || die "not authenticated to AWS -- run: aws configure${PROFILE:+  (profile $PROFILE)}"

if [ -n "$REGION_FLAG" ]; then
    REGIONS="$REGION_FLAG"
else
    REGIONS="$(aws ec2 describe-regions "${AWS_ARGS[@]}" --region "$HOME_REGION" \
                --query 'Regions[].RegionName' --output text 2>/dev/null)" \
        || die "could not list regions"
fi
REGION_COUNT="$(printf '%s\n' $REGIONS | grep -c .)"

printf '%sGraphwise tag audit%s  %saccount %s · %s region(s)%s\n' \
    "$BOLD$CYAN" "$RESET" "$DIM" "$ACCOUNT" "$REGION_COUNT" "$RESET"
printf '%srequired:' "$DIM"
for i in "${!EXPECTED_KEYS[@]}"; do
    printf ' %s=%s' "${EXPECTED_KEYS[$i]}" "${EXPECTED_VALS[$i]}"
done
printf '%s\n' "$RESET"
[ "$SAW_LEGACY_FLAG" -eq 1 ] && \
    info "note: --include-managed is now the default and does nothing; --skip-managed opts out."

KEYS_JSON="$(printf '%s\n' "${EXPECTED_KEYS[@]}" | jq -R . | jq -s -c .)"

# jq program shared by both sources. Emits, per resource:
#   <id> \t <all tag keys joined by |, or "-"> \t <ManagedBy> \t <one value per expected key>
# The "-" placeholder matters: an empty field would collapse under bash's
# tab-splitting and silently shift every column after it.
JQ_ROW='
  ($t | map(.Key) | join("|")) as $ks
  | [ $id,
      (if $ks == "" then "-" else $ks end),
      (($t | map(select(.Key == "ManagedBy")) | first | .Value) // "None")
    ]
    + ($keys | map(. as $k | (($t | map(select(.Key == $k)) | first | .Value) // "None")))
  | @tsv'

TMP="$(mktemp -d)" || die "could not create a temp dir"
trap 'rm -rf "$TMP"' EXIT

# ── sweep every region in parallel ───────────────────────────────────────────
info "sweeping ${REGION_COUNT} region(s) + global IAM ..."
for reg in $REGIONS; do
    (
        aws resourcegroupstaggingapi get-resources "${AWS_ARGS[@]}" --region "$reg" \
            --output json 2>/dev/null \
        | jq -r --argjson keys "$KEYS_JSON" \
            ".ResourceTagMappingList[] | .ResourceARN as \$id | (.Tags // []) as \$t | $JQ_ROW" \
            2>/dev/null > "$TMP/region-$reg.txt"
    ) &
done

# ── global: IAM roles (NOT covered by the Resource Groups Tagging API) ───────
(
    roles="$(aws iam list-roles "${AWS_ARGS[@]}" --query 'Roles[].RoleName' --output text 2>/dev/null)"
    for role in $roles; do
        (
            aws iam list-role-tags "${AWS_ARGS[@]}" --role-name "$role" --output json 2>/dev/null \
            | jq -r --argjson keys "$KEYS_JSON" --arg id "arn:aws:iam::${ACCOUNT}:role/${role}" \
                "(.Tags // []) as \$t | $JQ_ROW" 2>/dev/null > "$TMP/iam-$role.txt"
        ) &
    done
    wait
) &
wait

# ── parse everything into one record set ─────────────────────────────────────
# record: region \t kind \t scope \t type \t name \t id \t issues \t addspec \t delspec
RECORDS=""

add_record() {  # add_record <region> <kind> <arn> <allkeys> <managedby> <values...>
    local region="$1" kind="$2" arn="$3" allkeys="$4" managedby="$5"; shift 5
    local vals=("$@")
    local svc sub rest1 rest2 name type scope issues addspec delspec
    local i key want cur k variant

    IFS=':' read -r _ _ svc _ _ rest1 rest2 <<< "$arn"
    sub="${rest1%%/*}"
    name="${rest1#*/}"
    [ "$name" = "$rest1" ] && name="${rest2:-$rest1}"
    type="${svc}/${sub}"

    # Three-way scope:
    #   graphwise -- this kit's Terraform made it
    #   aws       -- Control Tower / StackSets / SSO / service-linked. Owned by
    #                the Organization; fixed too, unless --skip-managed. Some of
    #                these silently discard tag writes -- the verify pass catches it.
    #   other     -- everything else in the account (e.g. hand-allocated EIPs).
    #                Yours to fix, so treated like graphwise.
    # An `aws:`-prefixed tag key means AWS provisioned it (CloudFormation and
    # StackSets stamp aws:cloudformation:*), which catches Control Tower's VPC
    # resources whose own ARNs give nothing away.
    local is_managed=0
    case "$arn" in
        *ControlTower*|*controltower*|*AWSReservedSSO_*|*AWSServiceRoleFor*|\
        *:role/stacksets-exec-*|*:role/AuvariaSupportRole|\
        *:role/OrganizationAccountAccessRole|*aws-service-role*|\
        *:stack/StackSet-*|*aggregation-authorization*) is_managed=1 ;;
    esac
    case "|$allkeys" in *"|aws:"*) is_managed=1 ;; esac

    if [ "$managedby" = "terraform" ] || case "$arn" in *graphwise*) true ;; *) false ;; esac; then
        scope="graphwise"
    elif [ "$is_managed" -eq 1 ]; then
        scope="aws"
    else
        scope="other"
    fi

    issues=""; addspec=""; delspec=""
    for i in "${!EXPECTED_KEYS[@]}"; do
        key="${EXPECTED_KEYS[$i]}"; want="${EXPECTED_VALS[$i]}"
        cur="${vals[$i]:-None}"

        # Any tag key that differs from the canonical one ONLY by case is a
        # legacy mis-key: write the canonical key, then delete the variant.
        variant=""
        IFS='|' read -r -a _keys <<< "$allkeys"
        for k in "${_keys[@]}"; do
            if [ "$(lower "$k")" = "$(lower "$key")" ] && [ "$k" != "$key" ]; then
                variant="$k"; break
            fi
        done

        if [ -n "$variant" ]; then
            if [ "$cur" = "None" ]; then
                issues="${issues}${issues:+, }${variant} -> ${key} (rekey)"
                addspec="${addspec}${addspec:+|}${key}=${want}"
            elif [ "$cur" != "$want" ]; then
                issues="${issues}${issues:+, }${key} ${cur} -> ${want}, drop ${variant}"
                addspec="${addspec}${addspec:+|}${key}=${want}"
            else
                # canonical key is already correct -- this is purely a dupe
                issues="${issues}${issues:+, }duplicate ${variant} (remove)"
            fi
            delspec="${delspec}${delspec:+|}${variant}"
        elif [ "$cur" = "None" ]; then
            issues="${issues}${issues:+, }${key} missing"
            addspec="${addspec}${addspec:+|}${key}=${want}"
        elif [ "$cur" != "$want" ]; then
            issues="${issues}${issues:+, }${key} ${cur} -> ${want}"
            addspec="${addspec}${addspec:+|}${key}=${want}"
        fi
    done
    [ -z "$issues" ]  && issues="OK"
    [ -z "$addspec" ] && addspec="-"
    [ -z "$delspec" ] && delspec="-"

    RECORDS="${RECORDS}${region}"$'\t'"${kind}"$'\t'"${scope}"$'\t'"${type}"$'\t'"${name}"$'\t'"${arn}"$'\t'"${issues}"$'\t'"${addspec}"$'\t'"${delspec}"$'\n'
}

for f in "$TMP"/region-*.txt; do
    [ -f "$f" ] || continue
    reg="$(basename "$f" .txt)"; reg="${reg#region-}"
    while IFS=$'\t' read -r -a row; do
        [ "${#row[@]}" -lt 3 ] && continue
        add_record "$reg" "tagapi" "${row[0]}" "${row[1]}" "${row[2]}" "${row[@]:3}"
    done < "$f"
done

for f in "$TMP"/iam-*.txt; do
    [ -f "$f" ] || continue
    while IFS=$'\t' read -r -a row; do
        [ "${#row[@]}" -lt 3 ] && continue
        add_record "global" "iam-role" "${row[0]}" "${row[1]}" "${row[2]}" "${row[@]:3}"
    done < "$f"
done

if [ -z "$RECORDS" ]; then
    info "No tagged resources found. (Untagged resources are invisible to the tagging API -- see --help.)"
    exit 0
fi

# ── report ───────────────────────────────────────────────────────────────────
SORTED="$(printf '%s' "$RECORDS" | LC_ALL=C sort -t$'\t' -k1,1 -k4,4 -k5,5)"

print_header() {
    [ "$printed_header" -eq 1 ] && return
    printf '\n%s  %-13s %-34s %-20s %-9s %s%s\n' \
        "$DIM" "REGION" "RESOURCE" "TYPE" "SCOPE" "TAG STATUS" "$RESET"
    printed_header=1
}

FIX_REGIONS=(); FIX_KINDS=(); FIX_IDS=(); FIX_ADDS=(); FIX_DELS=(); FIX_LABELS=()
okc=0; skipped=0; bad=0; printed_header=0
while IFS=$'\t' read -r region kind scope type name arn issues addspec delspec; do
    [ -z "$arn" ] && continue
    dname="$name"
    [ "${#dname}" -gt 34 ] && dname="..${dname: -32}"

    # --list prints every asset, compliant or not, and changes nothing.
    if [ "$issues" = "OK" ]; then
        okc=$((okc+1))
        if [ "$LIST_ONLY" -eq 1 ]; then
            print_header
            printf '%s  %-13s %-34s %-20s %-9s ✓ compliant%s\n' \
                "$DIM" "$region" "$dname" "$type" "$scope" "$RESET"
        fi
        continue
    fi
    bad=$((bad+1))

    local_skip=0
    if [ "$scope" = "aws" ] && [ "$SKIP_MANAGED" -eq 1 ]; then
        skipped=$((skipped+1)); local_skip=1
    elif [ "$LIST_ONLY" -eq 0 ]; then
        FIX_REGIONS+=("$region"); FIX_KINDS+=("$kind"); FIX_IDS+=("$arn")
        FIX_ADDS+=("$addspec"); FIX_DELS+=("$delspec"); FIX_LABELS+=("$name")
    fi

    print_header
    if [ "$local_skip" -eq 1 ] && [ "$LIST_ONLY" -eq 0 ]; then
        printf '%s  %-13s %-34s %-20s %-9s %s (not fixed)%s\n' \
            "$DIM" "$region" "$dname" "$type" "$scope" "$issues" "$RESET"
    else
        printf '  %-13s %-34s %-20s %-9s %s%s%s\n' \
            "$region" "$dname" "$type" "$scope" "$YELLOW" "$issues" "$RESET"
    fi
done <<< "$SORTED"

echo
printf '%s%d compliant%s · %s%d non-compliant%s · %d resource(s) audited\n' \
    "$GREEN" "$okc" "$RESET" "$YELLOW" "$bad" "$RESET" "$((okc + bad))"

if [ "$LIST_ONLY" -eq 1 ]; then
    info "--list: read-only, nothing changed. Re-run without it to fix."
    exit 0
fi

[ "$skipped" -gt 0 ] && \
    info "${skipped} AWS/Control-Tower-managed resource(s) listed but NOT fixed (--skip-managed)."

fixcount=${#FIX_IDS[@]}
if [ "$fixcount" -eq 0 ]; then
    [ "$bad" -eq 0 ] && printf '%s✓%s every tagged resource carries the required tags.\n' "$GREEN" "$RESET"
    exit 0
fi

writes=0; removes=0
for s in "${FIX_ADDS[@]}"; do
    [ "$s" = "-" ] && continue
    IFS='|' read -r -a parts <<< "$s"; writes=$((writes + ${#parts[@]}))
done
for s in "${FIX_DELS[@]}"; do
    [ "$s" = "-" ] && continue
    IFS='|' read -r -a parts <<< "$s"; removes=$((removes + ${#parts[@]}))
done

echo
if [ "$removes" -gt 0 ]; then
    printf '%sThis removes %d legacy tag key(s) -- deletion cannot be undone.%s\n' \
        "$YELLOW" "$removes" "$RESET"
fi
printf 'Apply %s%d%s write(s) and %s%d%s removal(s) across %s%d%s resource(s)? [y/N]: ' \
    "$BOLD" "$writes" "$RESET" "$BOLD" "$removes" "$RESET" "$BOLD" "$fixcount" "$RESET"
read -r yn
case "$yn" in
    [Yy]|[Yy][Ee][Ss]) ;;
    *) echo "Aborted. No tags changed."; exit 1 ;;
esac
echo

# ── apply ────────────────────────────────────────────────────────────────────
# Two APIs, two tag argument shapes:
#   tagging API -> --tags key=value,key2=value2   /  --tag-keys k1 k2
#   IAM         -> --tags Key=k,Value=v ...       /  --tag-keys k1 k2
# Writes go first: if a removal later fails, the canonical tag is already in
# place, so the resource is never left with neither key.
fail=0
for i in "${!FIX_IDS[@]}"; do
    rc=0; out=""
    if [ "${FIX_ADDS[$i]}" != "-" ]; then
        IFS='|' read -r -a pairs <<< "${FIX_ADDS[$i]}"
        if [ "${FIX_KINDS[$i]}" = "iam-role" ]; then
            iamtags=()
            for p in "${pairs[@]}"; do iamtags+=("Key=${p%%=*},Value=${p#*=}"); done
            out="$(aws iam tag-role "${AWS_ARGS[@]}" \
                    --role-name "${FIX_IDS[$i]##*/}" --tags "${iamtags[@]}" 2>&1)" || rc=1
        else
            maptags=""
            for p in "${pairs[@]}"; do maptags="${maptags}${maptags:+,}${p}"; done
            out="$(aws resourcegroupstaggingapi tag-resources "${AWS_ARGS[@]}" \
                    --region "${FIX_REGIONS[$i]}" \
                    --resource-arn-list "${FIX_IDS[$i]}" --tags "$maptags" 2>&1)" || rc=1
            # tag-resources exits 0 on partial failure; failures land in FailedResourcesMap.
            [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"FailedResourcesMap": *{[^}]' && rc=1
        fi
    fi
    if [ "$rc" -eq 0 ] && [ "${FIX_DELS[$i]}" != "-" ]; then
        IFS='|' read -r -a dkeys <<< "${FIX_DELS[$i]}"
        if [ "${FIX_KINDS[$i]}" = "iam-role" ]; then
            out="$(aws iam untag-role "${AWS_ARGS[@]}" \
                    --role-name "${FIX_IDS[$i]##*/}" --tag-keys "${dkeys[@]}" 2>&1)" || rc=1
        else
            out="$(aws resourcegroupstaggingapi untag-resources "${AWS_ARGS[@]}" \
                    --region "${FIX_REGIONS[$i]}" \
                    --resource-arn-list "${FIX_IDS[$i]}" --tag-keys "${dkeys[@]}" 2>&1)" || rc=1
            [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '"FailedResourcesMap": *{[^}]' && rc=1
        fi
    fi
    if [ "$rc" -eq 0 ]; then
        printf '  %s✓%s %-34s %s%s%s\n' "$GREEN" "$RESET" "${FIX_LABELS[$i]}" \
            "$DIM" "${FIX_REGIONS[$i]}" "$RESET"
    else
        printf '  %s✗%s %-34s %s\n' "$RED" "$RESET" "${FIX_LABELS[$i]}" \
            "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-110)"
        fail=$((fail+1))
    fi
done

echo

# ── verify ───────────────────────────────────────────────────────────────────
# A tag write can succeed and change NOTHING: AWS silently ignores tag calls on
# service-managed resources (an EventBridge rule with ManagedBy set, say) --
# tag-resources returns 200 with an empty FailedResourcesMap and writes nothing.
# So re-read what we just wrote instead of trusting the API's word for it.
row_compliant() {  # row_compliant <tab row: arn, allkeys, managedby, values...>
    local r="$1" i; local -a f
    IFS=$'\t' read -r -a f <<< "$r"
    for i in "${!EXPECTED_KEYS[@]}"; do
        [ "${f[$((3+i))]:-None}" = "${EXPECTED_VALS[$i]}" ] || return 1
    done
    return 0
}

info "verifying ..."
verify_regions=""
for i in "${!FIX_IDS[@]}"; do
    [ "${FIX_KINDS[$i]}" = "iam-role" ] && continue
    case " $verify_regions " in *" ${FIX_REGIONS[$i]} "*) ;; *) verify_regions="$verify_regions ${FIX_REGIONS[$i]}" ;; esac
done
for reg in $verify_regions; do
    aws resourcegroupstaggingapi get-resources "${AWS_ARGS[@]}" --region "$reg" --output json 2>/dev/null \
    | jq -r --argjson keys "$KEYS_JSON" \
        ".ResourceTagMappingList[] | .ResourceARN as \$id | (.Tags // []) as \$t | $JQ_ROW" \
        2>/dev/null > "$TMP/verify-$reg.txt"
done

notstuck=0
for i in "${!FIX_IDS[@]}"; do
    if [ "${FIX_KINDS[$i]}" = "iam-role" ]; then
        row="$(aws iam list-role-tags "${AWS_ARGS[@]}" --role-name "${FIX_IDS[$i]##*/}" --output json 2>/dev/null \
               | jq -r --argjson keys "$KEYS_JSON" --arg id "${FIX_IDS[$i]}" \
                   "(.Tags // []) as \$t | $JQ_ROW" 2>/dev/null)"
    else
        row="$(grep -F "${FIX_IDS[$i]}"$'\t' "$TMP/verify-${FIX_REGIONS[$i]}.txt" 2>/dev/null | head -1)"
    fi
    if [ -z "$row" ] || ! row_compliant "$row"; then
        notstuck=$((notstuck+1))
        printf '  %s!%s %-34s %s\n' "$YELLOW" "$RESET" "${FIX_LABELS[$i]}" \
            "tags did NOT persist -- AWS is ignoring writes on this resource"
    fi
done

if [ "$notstuck" -gt 0 ]; then
    echo
    printf '%s✗%s %d resource(s) reported success but the tags did not stick.\n' \
        "$RED" "$RESET" "$notstuck"
    info "That means AWS itself owns them -- e.g. an EventBridge rule with"
    info "ManagedBy=controltower.amazonaws.com. Only the owning service can tag those;"
    info "re-running will not help. Raise it with whoever administers the Organization."
    exit 1
fi

if [ "$fail" -eq 0 ]; then
    printf '%s✓%s %d write(s) and %d removal(s) applied to %d resource(s), verified.\n' \
        "$GREEN" "$RESET" "$writes" "$removes" "$fixcount"
    info "Heads-up: tags on a teammate's stack are reverted by their next \`terraform apply\`"
    info "unless their terraform.tfvars carries the matching extra_tags block."
    exit 0
else
    printf '%s✗%s %d resource(s) failed -- see the errors above.\n' "$RED" "$RESET" "$fail"
    exit 1
fi
