#!/usr/bin/env bash
#
# Author:   Kent Stroker
# Created:  2026-07-19
# Modified: 2026-08-04
# Version:  2.4.0
#
# ec2-power.sh -- list Graphwise stack EC2 instances and start/stop one.
#
# Stand-alone laptop helper. It queries EC2 for the demo-stack instances this
# module creates (running AND stopped), shows them in a numbered menu, and lets
# you start a stopped one or stop a running one -- with a confirmation prompt
# before it touches anything.
#
# Scope: by default only instances tagged by this Terraform module
# (ManagedBy=terraform AND a Subdomain tag) are listed, so you can't fat-finger
# someone else's box in the shared PSE account. Pass --all to list every
# running/stopped instance in the region.
#
# Usage:
#   ./ec2-power.sh [--region <r>] [--profile <p>] [--all]
#
#   --region <r>   AWS region (default: $AWS_REGION / $AWS_DEFAULT_REGION /
#                  `aws configure get region` / us-west-2)
#   --profile <p>  AWS CLI profile (default: $AWS_PROFILE / CLI default)
#   --all          list every instance in the region, not just module-managed
#   -h, --help     this help
#
# Read-only until you confirm a start/stop. macOS-oriented.

set -uo pipefail

# ── colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    RED=$'\033[31m'; CYAN=$'\033[36m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; DIM=""; RESET=""
fi

die()  { printf '%s✗%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }
info() { printf '%s%s%s\n' "$DIM" "$1" "$RESET"; }

# EC2 LaunchTime -> local "Aug 03 18:49". LaunchTime tracks the most recent
# *start*, not the original launch, so for a stopped box it reads as "last
# started". BSD date only (macOS); falls back to the raw date on any failure.
fmt_started() {
    local raw="$1" epoch
    case "$raw" in ""|None) printf '%s' "-"; return ;; esac
    epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "${raw%%[+.Z]*}" '+%s' 2>/dev/null)" || epoch=""
    if [ -n "$epoch" ]; then
        date -r "$epoch" '+%b %d %H:%M' 2>/dev/null || printf '%s' "${raw%%T*}"
    else
        printf '%s' "${raw%%T*}"
    fi
}

# ── args ─────────────────────────────────────────────────────────────────────
REGION_FLAG=""; PROFILE_FLAG=""; ALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --region)  REGION_FLAG="${2:-}"; shift 2 || die "--region needs a value" ;;
        --profile) PROFILE_FLAG="${2:-}"; shift 2 || die "--profile needs a value" ;;
        --all)     ALL=1; shift ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "unknown argument: $1  (try --help)" ;;
    esac
done

# ── resolve region / profile ─────────────────────────────────────────────────
REGION="${REGION_FLAG:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
[ -z "$REGION" ] && REGION="$(aws configure get region 2>/dev/null || true)"
[ -z "$REGION" ] && REGION="us-west-2"

AWS_ARGS=(--region "$REGION")
PROFILE="${PROFILE_FLAG:-${AWS_PROFILE:-}}"
[ -n "$PROFILE" ] && AWS_ARGS+=(--profile "$PROFILE")

# ── preflight ────────────────────────────────────────────────────────────────
command -v aws >/dev/null 2>&1 || die "aws CLI not found -- install it, then: aws configure ${DIM}(region us-west-2)${RESET}"
ACCOUNT="$(aws sts get-caller-identity "${AWS_ARGS[@]}" --query Account --output text 2>/dev/null)" \
    || die "not authenticated to AWS -- run: aws configure${PROFILE:+  (profile $PROFILE)}"

printf '%sGraphwise EC2 power%s  %saccount %s · region %s%s\n\n' \
    "$BOLD$CYAN" "$RESET" "$DIM" "$ACCOUNT" "$REGION" "$RESET"

# ── query instances ──────────────────────────────────────────────────────────
FILTERS=(--filters "Name=instance-state-name,Values=running,stopped,stopping,pending")
if [ "$ALL" -eq 0 ]; then
    FILTERS+=("Name=tag:ManagedBy,Values=terraform" "Name=tag-key,Values=Subdomain")
fi

QUERY='Reservations[].Instances[].[InstanceId,State.Name,InstanceType,LaunchTime,Tags[?Key==`Name`]|[0].Value,Tags[?Key==`Subdomain`]|[0].Value,Tags[?Key==`Purpose`]|[0].Value]'

RAW="$(aws ec2 describe-instances "${AWS_ARGS[@]}" "${FILTERS[@]}" \
        --query "$QUERY" --output text 2>&1)" \
    || die "describe-instances failed: $RAW"

# sort by state, then Name (tab-delimited fields; Name is field 5)
RAW="$(printf '%s\n' "$RAW" | sed '/^$/d' | LC_ALL=C sort -t$'\t' -k2,2 -k5,5)"

if [ -z "$RAW" ]; then
    if [ "$ALL" -eq 0 ]; then
        info "No Graphwise-managed instances found in $REGION. (use --all to list every instance)"
    else
        info "No running or stopped instances found in $REGION."
    fi
    exit 0
fi

# ── parse into parallel arrays ───────────────────────────────────────────────
IDS=(); STATES=(); NAMES=()
n=0

printf '%s    %-22s %-9s %-12s %-11s %-19s %s%s\n' \
    "$DIM" "NAME" "STATE" "STARTED" "TYPE" "INSTANCE ID" "SUBDOMAIN · PURPOSE" "$RESET"

while IFS=$'\t' read -r id state itype launch name sub purpose; do
    [ -z "$id" ] && continue
    [ "$name" = "None" ] && name="(no name)"
    [ "$sub" = "None" ] && sub="-"
    [ "$purpose" = "None" ] && purpose="-"
    n=$((n+1))
    IDS+=("$id"); STATES+=("$state"); NAMES+=("$name")

    case "$state" in
        running)           sc="$GREEN" ;;
        stopped)           sc="$YELLOW" ;;
        pending|stopping)  sc="$CYAN" ;;
        *)                 sc="$DIM" ;;
    esac
    # Display-only trim: every module instance is named graphwise-<x>-ec2, so
    # the fixed prefix/suffix are noise. The confirm prompt below still shows
    # the FULL name -- that's the safety-critical spot, don't trim it there.
    # Anything still over-long (e.g. a --all instance) elides from the LEFT,
    # since the tail is what tells stacks apart.
    dname="${name#graphwise-}"
    dname="${dname%-ec2}"
    [ "${#dname}" -gt 22 ] && dname="..${dname: -20}"
    printf '%s%2d%s  %-22s %s%-9s%s %-12s %-11s %-19s %s%s · %s%s\n' \
        "$BOLD" "$n" "$RESET" \
        "$dname" \
        "$sc" "$state" "$RESET" \
        "$(fmt_started "$launch")" \
        "$itype" "$id" \
        "$DIM" "$sub" "$purpose" "$RESET"
done <<< "$RAW"

total=${#IDS[@]}
echo

# ── select ───────────────────────────────────────────────────────────────────
printf 'Select an instance [%s1-%d%s], or %sq%s to quit: ' "$BOLD" "$total" "$RESET" "$BOLD" "$RESET"
read -r choice
case "$choice" in
    q|Q|"") echo "Nothing to do."; exit 0 ;;
esac
case "$choice" in
    *[!0-9]*) die "not a number: $choice" ;;
esac
[ "$choice" -ge 1 ] && [ "$choice" -le "$total" ] || die "out of range: $choice (1-$total)"

idx=$((choice-1))
id="${IDS[$idx]}"; state="${STATES[$idx]}"; name="${NAMES[$idx]}"

# ── determine the valid action from current state ────────────────────────────
case "$state" in
    running)  verb="Stop";  cmd="stop-instances"  ;;
    stopped)  verb="Start"; cmd="start-instances" ;;
    *)        info "Instance '$name' is '$state' (a transitional state) -- let it settle, then re-run."; exit 0 ;;
esac

# ── confirm ──────────────────────────────────────────────────────────────────
printf '%s%s%s  %s (%s) is currently %s. Proceed? [y/N]: ' \
    "$BOLD" "$verb" "$RESET" "$name" "$id" "$state"
read -r yn
case "$yn" in
    [Yy]|[Yy][Ee][Ss]) ;;
    *) echo "Aborted."; exit 0 ;;
esac

# ── act ──────────────────────────────────────────────────────────────────────
NEW="$(aws ec2 "$cmd" "${AWS_ARGS[@]}" --instance-ids "$id" \
        --query "$( [ "$cmd" = start-instances ] && echo 'StartingInstances[0].CurrentState.Name' || echo 'StoppingInstances[0].CurrentState.Name' )" \
        --output text 2>&1)" \
    || die "$cmd failed: $NEW"

printf '%s✓%s %s -> %s%s%s\n' "$GREEN" "$RESET" "$name" "$BOLD" "$NEW" "$RESET"
info "Check state later with: aws ec2 describe-instances --instance-ids $id ${AWS_ARGS[*]} --query 'Reservations[].Instances[].State.Name' --output text"
