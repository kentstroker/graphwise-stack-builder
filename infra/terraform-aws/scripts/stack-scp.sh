#!/usr/bin/env bash
# stack-scp.sh -- scp wrapper that auto-fills GW_KEY / GW_HOST from ~/.zprofile
#
# Reads the GW_KEY_<name> / GW_HOST_<name> blocks written by manage-stacks.sh.
# Prefix any path with ':' to indicate the remote (EC2) side -- the same
# convention as scp itself. The script expands ':path' to 'ec2-user@<host>:path'.
#
# Usage:
#   ./prep-scripts/stack-scp.sh [--stack <name>] [-r] <source> <dest>
#
# Examples:
#   ./prep-scripts/stack-scp.sh logo.png :~/logo.png
#       push logo.png to the EC2 home directory (interactive stack picker)
#
#   ./prep-scripts/stack-scp.sh :~/wildcard-tls.yaml ./
#       pull wildcard-tls.yaml from the EC2 to the current directory
#
#   ./prep-scripts/stack-scp.sh --stack kstroker logo.png :~/logo.png
#       push to the kstroker stack without the picker
#
#   ./prep-scripts/stack-scp.sh -r ./data :~/staging-data/
#       recursive push (e.g. uploading a staging-data folder)
#
#   ./prep-scripts/stack-scp.sh --stack stroker -r :~/gsb/files/ ./local-backup/
#       recursive pull from a named stack
#
# Exit codes:
#   0 -- scp succeeded
#   1 -- bad arguments, no stacks configured, or scp failure

set -uo pipefail

ZPROFILE="${HOME}/.zprofile"

# ── colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    RED=$'\033[31m'; CYAN=$'\033[36m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; DIM=""; RESET=""
fi

die()  { echo "${RED}error:${RESET} $*" >&2; exit 1; }
info() { echo "${CYAN}→${RESET} $*"; }

# ── parse .zprofile ──────────────────────────────────────────────────────────
parse_stacks() {
    [ -f "${ZPROFILE}" ] || return 0
    grep -E '^# --- GW stack: .+ ---$' "${ZPROFILE}" \
        | sed 's/^# --- GW stack: //; s/ ---$//'
}

stack_key()  {
    grep -E "^export GW_KEY_${1}=" "${ZPROFILE}" 2>/dev/null \
        | head -1 | sed 's/^[^=]*=//; s/^"//; s/"$//' | sed "s|\\\${HOME}|${HOME}|g"
}
stack_host() {
    grep -E "^export GW_HOST_${1}=" "${ZPROFILE}" 2>/dev/null \
        | head -1 | sed 's/^[^=]*=//; s/^"//; s/"$//'
}

# ── argument parsing ─────────────────────────────────────────────────────────
STACK_NAME=""
SCP_FLAGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stack)
            shift
            [ $# -gt 0 ] || die "--stack requires a name argument."
            STACK_NAME="$1"
            shift
            ;;
        -r|-p|-q|-v|-C)
            SCP_FLAGS+=("$1")
            shift
            ;;
        -*)
            # Pass through any other scp flags (e.g. -P <port>, -i handled by us)
            SCP_FLAGS+=("$1")
            shift
            ;;
        *)
            break
            ;;
    esac
done

[ $# -eq 2 ] || die "Expected exactly two path arguments: <source> <dest>
Usage: stack-scp.sh [--stack <name>] [-r] <source> <dest>
  Prefix EC2 paths with ':' e.g.  logo.png :~/logo.png"

SRC="$1"
DST="$2"

# Validate that at least one side is remote
if [[ "$SRC" != :* ]] && [[ "$DST" != :* ]]; then
    die "Neither path is remote. Prefix the EC2 path with ':' (e.g. :~/file.txt)."
fi
if [[ "$SRC" == :* ]] && [[ "$DST" == :* ]]; then
    die "Both paths are remote. Only one path can be on the EC2."
fi

# ── stack selection ──────────────────────────────────────────────────────────
all_stacks=$(parse_stacks)
[ -n "$all_stacks" ] || die "No stacks found in ~/.zprofile. Run manage-stacks.sh add first."

if [ -z "$STACK_NAME" ]; then
    # Interactive picker
    echo
    echo "${BOLD}${CYAN}Select a stack:${RESET}"
    echo

    names=()
    i=1
    while IFS= read -r n; do
        names+=("$n")
        local_host=$(stack_host "$n")
        printf '  %d) %-14s  %s%s%s\n' "$i" "$n" "${DIM}" "${local_host}" "${RESET}"
        (( i++ ))
    done <<< "$all_stacks"

    echo
    read -rp "  Choice [1]: " choice
    choice="${choice:-1}"
    [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid choice."
    idx=$(( choice - 1 ))
    [ "$idx" -ge 0 ] && [ "$idx" -lt "${#names[@]}" ] || die "Number out of range."
    STACK_NAME="${names[$idx]}"
fi

# Validate the chosen stack exists
echo "$all_stacks" | grep -qx "$STACK_NAME" \
    || die "Stack '${STACK_NAME}' not found in ~/.zprofile. Run manage-stacks.sh list."

KEY=$(stack_key "$STACK_NAME")
HOST=$(stack_host "$STACK_NAME")
USER_NAME="ec2-user"

[ -n "$KEY" ]  || die "GW_KEY_${STACK_NAME} not found in ~/.zprofile."
[ -n "$HOST" ] || die "GW_HOST_${STACK_NAME} not found in ~/.zprofile."
[ -f "$KEY" ]  || die "Key file not found: ${KEY}"

# ── expand remote paths ──────────────────────────────────────────────────────
expand() {
    local path="$1"
    if [[ "$path" == :* ]]; then
        echo "${USER_NAME}@${HOST}:${path:1}"
    else
        echo "$path"
    fi
}

FULL_SRC=$(expand "$SRC")
FULL_DST=$(expand "$DST")

# ── run scp ──────────────────────────────────────────────────────────────────
echo
info "Stack:  ${BOLD}${STACK_NAME}${RESET}  (${HOST})"
info "Key:    ${DIM}${KEY}${RESET}"
echo

# Direction label
if [[ "$DST" == :* ]]; then
    info "Push:  ${SRC}  →  ${FULL_DST}"
else
    info "Pull:  ${FULL_SRC}  →  ${DST}"
fi
echo

CMD=(scp ${SCP_FLAGS[@]+"${SCP_FLAGS[@]}"} -i "$KEY" "$FULL_SRC" "$FULL_DST")
echo "  ${DIM}${CMD[*]}${RESET}"
echo

exec "${CMD[@]}"
