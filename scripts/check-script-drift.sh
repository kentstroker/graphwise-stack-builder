#!/usr/bin/env bash
# check-script-drift.sh -- catch the two copies of a shared laptop script
# drifting apart.
#
# infra/<cloud>/ trees are deliberately self-contained: each cloud is kept
# distinctly separate, so the cloud-agnostic operator scripts (manage-stacks.sh,
# stack-scp.sh, pull-config.sh, push-config.sh) are DUPLICATED into each cloud's
# scripts/ directory rather than shared from one place. That is a deliberate
# trade -- each tree stands alone -- but nothing in the repo enforces that the
# copies stay identical, and there is no CI here to notice.
#
# This is not a hypothetical failure. The separate laptop kit's copies of these
# same four scripts were measured at 13-28 differing lines against the repo's
# copies: each was edited once, in one place, and the other was forgotten. The
# drift is invisible until an operator on the other cloud hits a bug that was
# fixed months ago.
#
# Two checks, both keyed off what is actually on disk rather than a hardcoded
# layout, so a directory rename (terraform-example -> terraform-aws -> aws)
# does not silently disable them:
#
#   DRIFT    a file name that appears in more than one infra/*/scripts/ tree,
#            whose contents differ between them.
#   MISSING  a name in EXPECTED_SHARED present in one cloud tree but absent
#            from another -- someone added the file to one side only.
#
# DRIFT always fails. MISSING only warns by default, because the two cases are
# not equally conclusive: two copies that disagree are wrong no matter what,
# while a copy that is absent may simply mean the duplication has not been done
# yet. Pass --strict once every cloud tree is fully populated to make MISSING
# fail too -- that is the setting that catches a later one-sided addition.
#
# Exit status is 0 when clean, 1 when drift is found (or, under --strict, when
# anything is), so this can be wired into a pre-commit hook or release checklist.
#
# Usage: scripts/check-script-drift.sh [--diff] [--list] [--strict] [-h|--help]
#   --diff   print the full unified diff for each drifted file
#   --list   show every file being compared, including the clean ones
#   --strict treat MISSING as a failure, not a warning
#   -h       this help
#
# bash 3.2 compatible (macOS built-in bash).

set -uo pipefail

# Scripts that are meant to exist, identically, in every cloud tree. Adding a
# name here makes its absence from a cloud tree an error, not just its drift.
EXPECTED_SHARED="manage-stacks.sh stack-scp.sh pull-config.sh push-config.sh"

SHOW_DIFF=0
SHOW_LIST=0
STRICT=0

usage() { sed -n '2,/^# bash 3.2/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --diff) SHOW_DIFF=1; shift ;;
        --list) SHOW_LIST=1; shift ;;
        --strict) STRICT=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 2 ;;
    esac
done

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RESET=$(printf '\033[0m')
    GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); RED=$(printf '\033[31m')
else
    BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""; RED=""
fi

# Repo root: prefer git, fall back to this script's parent so the check still
# works in an exported tree with no .git.
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Discover the cloud script trees. Globbing infra/*/scripts keeps this working
# across the directory renames this repo has already been through twice.
CLOUD_DIRS=""
for d in "$REPO_ROOT"/infra/*/scripts; do
    [ -d "$d" ] || continue
    CLOUD_DIRS="$CLOUD_DIRS $d"
done
CLOUD_DIRS="${CLOUD_DIRS# }"

if [ -z "$CLOUD_DIRS" ]; then
    printf '%sNo infra/*/scripts directories found under %s%s\n' "$YELLOW" "$REPO_ROOT" "$RESET"
    printf '  %sNothing to compare -- has the tree been restructured?%s\n' "$DIM" "$RESET"
    exit 0
fi

n_trees=0
for d in $CLOUD_DIRS; do n_trees=$((n_trees + 1)); done

printf '%sScript drift check%s  %s%s tree(s) under infra/%s\n' \
    "$BOLD" "$RESET" "$DIM" "$n_trees" "$RESET"
for d in $CLOUD_DIRS; do
    printf '  %s%s%s\n' "$DIM" "${d#$REPO_ROOT/}" "$RESET"
done
echo

# ---------------------------------------------------------------------------
# Check 1 -- DRIFT: same file name in 2+ trees with differing contents.
# ---------------------------------------------------------------------------
# Duplicated names are found from disk, not from EXPECTED_SHARED, so a script
# duplicated later is covered automatically without editing this file.
DUP_NAMES="$(
    for d in $CLOUD_DIRS; do
        ls -1 "$d" 2>/dev/null | grep '\.sh$' || true
    done | sort | uniq -d
)"

DRIFTED=0
COMPARED=0

if [ -n "$DUP_NAMES" ]; then
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        # every tree that carries this name
        holders=""
        for d in $CLOUD_DIRS; do
            [ -f "$d/$name" ] && holders="$holders $d"
        done
        holders="${holders# }"

        # compare each subsequent copy against the first
        first=""
        for d in $holders; do
            if [ -z "$first" ]; then first="$d"; continue; fi
            COMPARED=$((COMPARED + 1))
            if diff -q "$first/$name" "$d/$name" >/dev/null 2>&1; then
                [ "$SHOW_LIST" -eq 1 ] && \
                    printf '  %s=%s %-22s %s\n' "$GREEN" "$RESET" "$name" \
                        "${DIM}identical in ${first#$REPO_ROOT/} and ${d#$REPO_ROOT/}${RESET}"
            else
                DRIFTED=$((DRIFTED + 1))
                nlines="$(diff -u "$first/$name" "$d/$name" 2>/dev/null | grep -c '^[+-][^+-]' || true)"
                printf '  %sDRIFT%s %-22s %s differing line(s)\n' "$RED" "$RESET" "$name" "$nlines"
                printf '        %s%s%s\n' "$DIM" "${first#$REPO_ROOT/}/$name" "$RESET"
                printf '        %s%s%s\n' "$DIM" "${d#$REPO_ROOT/}/$name" "$RESET"
                if [ "$SHOW_DIFF" -eq 1 ]; then
                    echo
                    diff -u "$first/$name" "$d/$name" | sed 's/^/        /'
                    echo
                fi
            fi
        done
    done <<EOF
$DUP_NAMES
EOF
fi

# ---------------------------------------------------------------------------
# Check 2 -- MISSING: an expected-shared script absent from a cloud tree.
# ---------------------------------------------------------------------------
MISSING=0
for name in $EXPECTED_SHARED; do
    present=""; absent=""
    for d in $CLOUD_DIRS; do
        if [ -f "$d/$name" ]; then present="$present $d"; else absent="$absent $d"; fi
    done
    # Only a problem once the script exists SOMEWHERE. A name that is nowhere
    # yet is a duplication that has not happened, not a regression.
    [ -n "$present" ] || continue
    [ -n "$absent" ] || continue
    for d in $absent; do
        MISSING=$((MISSING + 1))
        printf '  %sMISSING%s %-20s absent from %s\n' "$YELLOW" "$RESET" "$name" "${d#$REPO_ROOT/}"
        for p in $present; do
            printf '        %spresent in %s%s\n' "$DIM" "${p#$REPO_ROOT/}" "$RESET"
        done
    done
done

# ---------------------------------------------------------------------------
echo
printf '%s──────────────────────────────────────────────────────────────%s\n' "$DIM" "$RESET"
# MISSING is advisory unless --strict; DRIFT always fails.
FAILED="$DRIFTED"
[ "$STRICT" -eq 1 ] && FAILED=$((DRIFTED + MISSING))

if [ "$DRIFTED" -eq 0 ] && [ "$MISSING" -eq 0 ]; then
    if [ "$COMPARED" -eq 0 ]; then
        printf '%sNo duplicated scripts to compare yet.%s\n' "$GREEN" "$RESET"
        printf '  %sThe cloud trees share no file names. Once a shared script is copied%s\n' "$DIM" "$RESET"
        printf '  %sinto a second tree, this check starts guarding it automatically.%s\n' "$DIM" "$RESET"
    else
        printf '%sClean -- %s comparison(s), no drift.%s\n' "$GREEN" "$COMPARED" "$RESET"
    fi
    exit 0
fi

printf '%s%s drifted, %s missing.%s\n' "$BOLD" "$DRIFTED" "$MISSING" "$RESET"
printf '  %sThese trees are duplicated on purpose; keeping them in sync is manual.%s\n' "$DIM" "$RESET"
if [ "$DRIFTED" -gt 0 ]; then
    printf '  %sRe-run with --diff to see what changed, then apply the fix to BOTH copies.%s\n' "$DIM" "$RESET"
fi
if [ "$MISSING" -gt 0 ] && [ "$STRICT" -eq 0 ]; then
    printf '  %sMISSING is advisory here -- it also reads as "not duplicated yet".%s\n' "$DIM" "$RESET"
    printf '  %sOnce every cloud tree is populated, run with --strict to enforce it.%s\n' "$DIM" "$RESET"
fi
[ "$FAILED" -eq 0 ] && exit 0
exit 1
