#!/usr/bin/env bash
# manage-stacks.sh -- add / remove / list Graphwise stack SSH entries in ~/.zprofile
#
# Each stack gets a labeled block written into ~/.zprofile:
#
#   # --- GW stack: stroker ---
#   export GW_KEY_stroker="${HOME}/.ssh/stroker-stack-key.pem"
#   export GW_HOST_stroker="stroker.gw-pse.com"
#   alias sshstroker='ssh -i ${GW_KEY_stroker} ${GW_USER}@${GW_HOST_stroker}'
#   # --- end GW stack: stroker ---
#
# GW_USER=ec2-user is written once and shared by all stacks (always ec2-user).
# Sentinel comments make blocks safe to add and remove without touching anything else.
#
# Usage:
#   ./prep-scripts/manage-stacks.sh            interactive menu
#   ./prep-scripts/manage-stacks.sh list       print all stacks and exit
#   ./prep-scripts/manage-stacks.sh add        add a new stack (prompts)
#   ./prep-scripts/manage-stacks.sh remove     remove a stack (prompts)
#
# After any change the script prints the source command -- run it (or open
# a new terminal) to pick up the new aliases.
#
# Exit codes:
#   0 -- success / no changes needed
#   1 -- user abort or fatal error

set -uo pipefail

ZPROFILE="${HOME}/.zprofile"

# ── colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    RED=$'\033[31m'; CYAN=$'\033[36m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; DIM=""; RESET=""
fi

# ── helpers ──────────────────────────────────────────────────────────────────
die()  { echo "${RED}error:${RESET} $*" >&2; exit 1; }
info() { echo "${CYAN}→${RESET} $*"; }
ok()   { echo "${GREEN}✓${RESET} $*"; }
warn() { echo "${YELLOW}!${RESET} $*"; }

# Return all stack names currently in .zprofile (one per line).
parse_stacks() {
    [ -f "${ZPROFILE}" ] || return 0
    grep -E '^# --- GW stack: .+ ---$' "${ZPROFILE}" \
        | sed 's/^# --- GW stack: //; s/ ---$//'
}

# Read a specific field for a named stack.
stack_key()   { local sv; sv=$(safe_var "$1"); grep -E "^export GW_KEY_${sv}=" "${ZPROFILE}" 2>/dev/null | head -1 | sed 's/^[^=]*=//; s/^"//; s/"$//'; }
stack_host()  { local sv; sv=$(safe_var "$1"); grep -E "^export GW_HOST_${sv}=" "${ZPROFILE}" 2>/dev/null | head -1 | sed 's/^[^=]*=//; s/^"//; s/"$//'; }
# Extract the alias name from inside the sentinel block for this stack.
stack_alias() {
    awk -v start="# --- GW stack: ${1} ---" -v end="# --- end GW stack: ${1} ---" '
        $0==start{f=1;next} $0==end{f=0} f && /^alias /{sub(/^alias /,""); sub(/=.*/,""); print; exit}
    ' "${ZPROFILE}" 2>/dev/null
}

# Check whether GW_USER is already set.
has_gw_user() { grep -qE '^export GW_USER=' "${ZPROFILE}" 2>/dev/null; }

# Return a variable-safe version of a stack name (hyphens → underscores).
safe_var() { echo "${1//-/_}"; }

# ── list ─────────────────────────────────────────────────────────────────────
cmd_list() {
    echo
    echo "${BOLD}${CYAN}Graphwise stacks in ~/.zprofile${RESET}"
    echo

    local stacks
    stacks=$(parse_stacks)
    if [ -z "$stacks" ]; then
        echo "  ${DIM}No stacks configured yet. Run:  manage-stacks.sh add${RESET}"
        echo
        return 0
    fi

    printf '  %-16s  %-12s  %-38s  %s\n' \
        "${BOLD}ALIAS${RESET}" "${BOLD}NAME${RESET}" "${BOLD}HOST${RESET}" "${BOLD}KEY${RESET}"
    printf '  %-16s  %-12s  %-38s  %s\n' \
        "──────────────" "────────────" "──────────────────────────────────────" "───────────────────"

    while IFS= read -r name; do
        local host key alias_name
        host=$(stack_host "$name")
        key=$(stack_key "$name")
        alias_name=$(stack_alias "$name")
        printf '  %-16s  %-12s  %-38s  %s\n' \
            "${GREEN}${alias_name}${RESET}" "$name" "$host" "${DIM}${key}${RESET}"
    done <<< "$stacks"

    echo
    if has_gw_user; then
        echo "  ${DIM}GW_USER=ec2-user  (universal — shared by all stacks)${RESET}"
    fi
    echo
}

# ── add ──────────────────────────────────────────────────────────────────────
cmd_add() {
    echo
    echo "${BOLD}${CYAN}Add a new Graphwise stack${RESET}"
    echo

    # Stack name
    local name
    read -rp "  Stack name (e.g. kstroker, kaiser): " name
    name="${name// /}"
    [ -z "$name" ] && die "Stack name cannot be empty."
    if parse_stacks | grep -qx "$name"; then
        die "Stack '${name}' already exists. Remove it first or choose a different name."
    fi

    # Host
    local host_default="${name}.gw-pse.com"
    local host
    read -rp "  Hostname [${host_default}]: " host
    host="${host:-$host_default}"

    # Key path
    local key_default="${HOME}/.ssh/${name}-stack-key.pem"
    local key
    read -rp "  Path to .pem key [${key_default}]: " key
    key="${key:-$key_default}"
    # Expand ~ manually (read doesn't expand it)
    key="${key/#\~/$HOME}"

    if [ ! -f "$key" ]; then
        warn "Key file not found: ${key}"
        warn "Adding anyway — make sure the file exists before you SSH."
    fi

    # Alias name
    local alias_default="ssh${name}"
    local alias_name
    read -rp "  SSH alias name [${alias_default}]: " alias_name
    alias_name="${alias_name:-$alias_default}"
    alias_name="${alias_name// /}"
    [ -z "$alias_name" ] && die "Alias name cannot be empty."

    local sv; sv=$(safe_var "$name")

    echo
    echo "  Will add to ~/.zprofile:"
    echo "  ${DIM}export GW_KEY_${sv}=\"${key}\"${RESET}"
    echo "  ${DIM}export GW_HOST_${sv}=\"${host}\"${RESET}"
    echo "  ${DIM}alias ${alias_name}='ssh -i \${GW_KEY_${sv}} \${GW_USER}@\${GW_HOST_${sv}}'${RESET}"
    echo
    read -rp "  Confirm? [Y/n]: " yn
    case "${yn:-Y}" in
        [Yy]*) ;;
        *) echo "Aborted."; exit 0 ;;
    esac

    # Create .zprofile if it doesn't exist
    [ -f "${ZPROFILE}" ] || touch "${ZPROFILE}"

    # Write GW_USER once if missing
    if ! has_gw_user; then
        {
            echo ""
            echo "# Graphwise stack SSH -- managed by manage-stacks.sh"
            echo "export GW_USER=ec2-user"
        } >> "${ZPROFILE}"
        info "Added GW_USER=ec2-user to ~/.zprofile"
    fi

    # Append the stack block (sentinel uses display name; vars use safe name)
    {
        echo ""
        echo "# --- GW stack: ${name} ---"
        echo "export GW_KEY_${sv}=\"${key}\""
        echo "export GW_HOST_${sv}=\"${host}\""
        printf "alias %s='ssh -i \${GW_KEY_%s} \${GW_USER}@\${GW_HOST_%s}'\n" \
            "$alias_name" "$sv" "$sv"
        echo "# --- end GW stack: ${name} ---"
    } >> "${ZPROFILE}"

    echo
    ok "Stack '${name}' added."
    echo
    echo "  Run this to activate now (or open a new terminal):"
    echo "  ${BOLD}source ~/.zprofile${RESET}"
    echo "  Then: ${GREEN}${alias_name}${RESET}"
    echo
}

# ── remove ───────────────────────────────────────────────────────────────────
cmd_remove() {
    echo
    echo "${BOLD}${CYAN}Remove a Graphwise stack${RESET}"
    echo

    local stacks
    stacks=$(parse_stacks)
    if [ -z "$stacks" ]; then
        echo "  No stacks configured."
        exit 0
    fi

    # Numbered menu
    local names=()
    local i=1
    while IFS= read -r n; do
        names+=("$n")
        local host
        host=$(stack_host "$n")
        printf '  %d) %s  %s%s%s\n' "$i" "$n" "${DIM}" "$host" "${RESET}"
        (( i++ ))
    done <<< "$stacks"

    echo
    local choice
    read -rp "  Stack number to remove (or q to quit): " choice
    [[ "$choice" =~ ^[Qq] ]] && { echo "Aborted."; exit 0; }
    [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid choice."
    local idx=$(( choice - 1 ))
    [ "$idx" -ge 0 ] && [ "$idx" -lt "${#names[@]}" ] || die "Number out of range."

    local name="${names[$idx]}"
    local rm_alias
    rm_alias=$(stack_alias "$name")
    echo
    warn "This will remove the '${name}' block from ~/.zprofile."
    read -rp "  Confirm removal of ${rm_alias}? [y/N]: " yn
    case "${yn:-N}" in
        [Yy]*) ;;
        *) echo "Aborted."; exit 0 ;;
    esac

    # Back up .zprofile before editing
    cp "${ZPROFILE}" "${ZPROFILE}.bak"

    # Remove the sentinel-delimited block using awk (portable, no sed -i quirks)
    local start="# --- GW stack: ${name} ---"
    local end="# --- end GW stack: ${name} ---"
    awk -v start="$start" -v end="$end" '
        $0 == start { skip=1; next }
        skip && $0 == end { skip=0; next }
        !skip { print }
    ' "${ZPROFILE}.bak" > "${ZPROFILE}"

    echo
    ok "Stack '${name}' removed. Backup: ~/.zprofile.bak"
    echo
    echo "  Run this to deactivate the alias now:"
    echo "  ${BOLD}source ~/.zprofile${RESET}"
    echo
}

# ── interactive menu ─────────────────────────────────────────────────────────
cmd_menu() {
    clear
    echo "${BOLD}${CYAN}Graphwise Stack SSH Manager${RESET}"
    cmd_list

    echo "  1) Add a stack"
    echo "  2) Remove a stack"
    echo "  3) List stacks"
    echo "  q) Quit"
    echo
    read -rp "  Choose: " choice
    echo
    case "$choice" in
        1) cmd_add ;;
        2) cmd_remove ;;
        3) cmd_list ;;
        [Qq]*) exit 0 ;;
        *) warn "Unknown choice."; exit 1 ;;
    esac
}

# ── main ─────────────────────────────────────────────────────────────────────
case "${1:-menu}" in
    list)   cmd_list ;;
    add)    cmd_add ;;
    remove) cmd_remove ;;
    menu)   cmd_menu ;;
    *) die "Unknown command '${1}'. Usage: manage-stacks.sh [list|add|remove]" ;;
esac
