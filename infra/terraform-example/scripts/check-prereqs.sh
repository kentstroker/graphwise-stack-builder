#!/usr/bin/env bash
# check-prereqs.sh -- laptop preflight for the Graphwise stack toolchain.
#
# Stand-alone: run this on your Mac BEFORE anything else. It verifies the OS,
# the required CLI tools, AWS auth, Python/PyYAML, and your working folder --
# the same prerequisites documented in NEW-STACK.md §0 and SETUP.md. It changes
# nothing; it only reports what's present and what to install.
#
# macOS only at this time.
set -uo pipefail   # NOT -e -- we want to run EVERY check, not bail on the first miss.

# ── colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    BOLD=$'\033[1m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    RED=$'\033[31m'; CYAN=$'\033[36m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; DIM=""; RESET=""
fi

clear

echo "${BOLD}${CYAN}Graphwise stack -- laptop prerequisites check${RESET}"
echo

FAIL=0
WARN=0
ok()   { printf '  %s\xe2\x9c\x93%s %s\n' "$GREEN"  "$RESET" "$1"; }
bad()  { printf '  %s\xe2\x9c\x97%s %s\n' "$RED"    "$RESET" "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  %s!%s %s\n'            "$YELLOW" "$RESET" "$1"; WARN=$((WARN+1)); }

# ── 1. OS gate: macOS only ───────────────────────────────────────────────────
OS="$(uname -s 2>/dev/null || echo unknown)"
case "$OS" in
    Darwin)
        ok "macOS $(sw_vers -productVersion 2>/dev/null || echo '(version unknown)') on $(uname -m)"
        ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
        echo "  ${YELLOW}Windows isn't in scope yet -- this toolchain is macOS only at this time.${RESET}"
        echo "  ${DIM}Reach out to Kent if you need a Windows path.${RESET}"
        exit 1
        ;;
    *)
        echo "  ${YELLOW}This looks like ${OS}, not macOS -- the laptop toolchain is macOS only at this time.${RESET}"
        exit 1
        ;;
esac
echo

# ── 2. required CLI tools ────────────────────────────────────────────────────
echo "${BOLD}Required tools${RESET}"
check_cmd() {  # check_cmd <cmd> <label> <install-hint> [<version-cmd>]
    local cmd="$1" label="$2" hint="$3" vcmd="${4:-}" v=""
    if command -v "$cmd" >/dev/null 2>&1; then
        [ -n "$vcmd" ] && v="$($vcmd 2>&1 | head -1)"
        ok "${label}${v:+  ${DIM}${v}${RESET}}"
    else
        bad "${label} missing -- ${hint}"
    fi
}
check_cmd brew      "Homebrew (brew)" 'install: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' "brew --version"
check_cmd aws       "AWS CLI (aws)"   "install: brew install awscli"    "aws --version"
check_cmd terraform "Terraform"       "install: brew install terraform" "terraform version"
check_cmd git       "git"             "install: xcode-select --install" "git --version"
check_cmd ssh       "ssh"             "ships with macOS"                "ssh -V"
check_cmd dig       "dig"             "ships with macOS (bind)"         "dig -v"
check_cmd jq        "jq"              "install: brew install jq"        "jq --version"
check_cmd python3   "Python 3"        "install: brew install python"    "python3 --version"
echo

# ── 3. Python modules (push/pull-config.sh splice YAML with PyYAML) ──────────
echo "${BOLD}Python modules${RESET}"
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
    ok "PyYAML"
else
    bad "PyYAML missing -- install: pip3 install --user pyyaml   ${DIM}(push/pull-config.sh need it)${RESET}"
fi
echo

# ── 4. AWS authentication ────────────────────────────────────────────────────
echo "${BOLD}AWS authentication${RESET}"
if command -v aws >/dev/null 2>&1; then
    IDENT="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
    if [ -n "$IDENT" ]; then
        ok "authenticated  ${DIM}${IDENT}${RESET}"
    else
        warn "aws installed but not authenticated -- run: aws configure  ${DIM}(region us-west-2, keys from your CSV)${RESET}"
    fi
else
    warn "skipped (aws not installed)"
fi
echo

# ── 5. working folder ────────────────────────────────────────────────────────
echo "${BOLD}Working folder${RESET}"
GSB="$HOME/Desktop/gsb"
if [ -d "$GSB" ]; then
    ok "$GSB exists"
else
    bad "$GSB not found -- create it: mkdir -p \"$GSB\"   ${DIM}(your Graphwise stack working folder)${RESET}"
fi
echo

# ── 6. IDE recommendation (not required) ─────────────────────────────────────
echo "${BOLD}Recommended (not required)${RESET}"
# LaunchServices lookup via `osascript 'id of app'` finds an installed app
# WHEREVER it lives (/Applications, ~/Applications, or a JetBrains Toolbox deep
# path) without launching it -- unlike a fixed /Applications/*.app glob.
IDE_FOUND=""
for _ide in "Visual Studio Code" "PyCharm" "PyCharm CE" "IntelliJ IDEA" \
            "IntelliJ IDEA CE" "DataGrip" "GoLand" "WebStorm" "CLion" "RustRover"; do
    if osascript -e "id of app \"$_ide\"" >/dev/null 2>&1; then
        IDE_FOUND="$_ide"; break
    fi
done
if [ -n "$IDE_FOUND" ]; then
    ok "IDE detected: ${IDE_FOUND}"
else
    warn "no IDE detected -- consider VS Code or a JetBrains IDE (PyCharm / IntelliJ)."
fi
echo "  ${DIM}Jupyter Notebooks are used in many demos & workshops (with more to come),${RESET}"
echo "  ${DIM}so a notebook-capable IDE -- VS Code + the Python/Jupyter extension, or a${RESET}"
echo "  ${DIM}JetBrains IDE -- makes running those a lot smoother.${RESET}"
echo

# ── summary ──────────────────────────────────────────────────────────────────
echo "${BOLD}--------------------------------------------------------------${RESET}"
MSG_WARN=""; [ "$WARN" -gt 0 ] && MSG_WARN="  (${WARN} warning(s) above)"
if [ "$FAIL" -eq 0 ]; then
    echo "${GREEN}${BOLD}All required prerequisites are in place.${RESET}${MSG_WARN}"
    echo "Next: follow DEPLOYMENT_GUIDE.md to provision your stack."
    echo "${DIM}(AWS account items -- EC2 key pair, Elastic IP, Route 53 DNS -- are in NEW-STACK.md / SETUP.md.)${RESET}"
    exit 0
else
    echo "${RED}${BOLD}${FAIL} required check(s) failed${RESET}${MSG_WARN}. Fix the marked items above, then re-run."
    exit 1
fi
