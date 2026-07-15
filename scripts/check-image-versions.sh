#!/usr/bin/env bash
# check-image-versions.sh -- check, upgrade, and (optionally) apply container
# image updates to a LIVE stack, in place, without a destroy.
#
# Reads current image tags from every chart values file, fetches the latest
# published semver tag for each image from Docker Hub, displays a comparison
# table, and offers to upgrade each outdated image interactively (editing the
# chart values under ~/gsb/charts in place). After edits it runs
# `helm dependency update` to rebuild the umbrella's bundled tarballs.
#
# With --apply it then rolls the running stack to the new images WITHOUT
# destroying data: for each upgraded image it `docker pull`s the new tag and
# `kind load`s it into the cluster, then does a non-destructive `helm upgrade`
# of the graphwise-stack (umbrella) release -- every catalogued image lives in
# that release -- reusing the deployment's existing values overlays. PVCs are
# retained, so the upgrade is in-place.
#
# Run from: the EC2, in ~/gsb. Prerequisites: curl, jq; plus helm, docker,
#   kind, kubectl and a deployed graphwise-stack release for --apply.
#
# Usage: scripts/check-image-versions.sh [--yes] [--apply] [--timeout <dur>]
#   --yes            accept all available upgrades without prompting
#   --apply          after editing, roll the live stack (docker pull + kind
#                    load + non-destructive helm upgrade of graphwise-stack)
#   --timeout <dur>  helm upgrade timeout for --apply (default 15m)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

AUTO_YES=0
APPLY=0
HELM_TIMEOUT="15m"
while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)  AUTO_YES=1; shift ;;
        --apply)   APPLY=1; shift ;;
        --timeout) HELM_TIMEOUT="${2:?--timeout requires a value (e.g. 15m)}"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ─── colors ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; CYAN=""; BOLD=""; DIM=""; RESET=""
fi

# ─── prereqs ─────────────────────────────────────────────────────────────────
for cmd in curl jq; do
    command -v "$cmd" &>/dev/null || { echo "${RED}ERROR${RESET}: $cmd not found in PATH" >&2; exit 1; }
done
command -v helm &>/dev/null || { echo "${YELLOW}WARN${RESET}: helm not found — will skip dependency rebuild" >&2; HAVE_HELM=0; }
HAVE_HELM=${HAVE_HELM:-1}

# ─── Docker Hub API ──────────────────────────────────────────────────────────
# fetch_latest NAMESPACE IMAGE TAG_REGEX
# Queries up to 2 pages (200 tags, ordered by most-recently-pushed) and returns
# the highest version string that matches TAG_REGEX, using version sort.
fetch_latest() {
    local ns="$1" img="$2" filter="$3"
    local all_tags="" page
    for page in 1 2; do
        local url="https://hub.docker.com/v2/repositories/${ns}/${img}/tags?page_size=100&page=${page}&ordering=last_updated"
        local batch
        batch=$(curl -fsSL --max-time 15 "$url" 2>/dev/null | jq -r '.results[].name' 2>/dev/null) || true
        [ -z "$batch" ] && break
        all_tags="${all_tags}${batch}"$'\n'
    done
    echo "$all_tags" | grep -E "$filter" | sort -V | tail -1
}

# ─── In-place sed (macOS + Linux portable) ───────────────────────────────────
sed_inplace() {
    local file="$1"; shift
    local tmp
    tmp=$(mktemp)
    sed "$@" "$file" > "$tmp" && mv "$tmp" "$file"
}

# ─── Image catalogue ─────────────────────────────────────────────────────────
# Each entry: "LABEL|HUB_NS|HUB_IMAGE|TAG_REGEX|TYPE"
# TYPE controls how the tag is read/written:
#   standard  — `tag: "X.Y.Z"` in a values file with 2-space indent
#   addon     — same but under a parent key (4-space indent) in addons/values.yaml
#   inline    — `image: IMAGE:TAG` on one line (no separate tag: field)
#   skip      — intentionally pinned, display only

IMAGES=(
    "PoolParty|ontotext|poolparty|^[0-9]+\.[0-9]+\.[0-9]+\$|standard"
    "GraphDB|ontotext|graphdb|^[0-9]+\.[0-9]+\.[0-9]+\$|standard"
    "Elasticsearch|ontotext|poolparty-elasticsearch|^[0-9]+\.[0-9]+\.[0-9]+\$|standard"
    "nginx (console)|library|nginx|^[0-9]+\.[0-9]+\.[0-9]+\$|standard"
    "ADF|ontotext|adf|^[0-9]+\.[0-9]+\.[0-9]+\$|addon"
    "Semantic Workbench|ontotext|semantic-workbench|^[0-9]+\.[0-9]+\.[0-9]+\$|addon"
    "GraphViews|ontotext|graphviews|^[0-9]+\.[0-9]+\.[0-9]+\$|addon"
    "RDF4J|eclipse|rdf4j-workbench|^[0-9]+\.[0-9]+\.[0-9]+\$|addon"
    "UnifiedViews|ontotext|unifiedviews|^[0-9]+\.[0-9]+\.[0-9]+\$|addon"
    "Refine|ontotext|refine|^[0-9]+\.[0-9]+\.[0-9]+\$|addon"
    "alpine (Jobs)|library|alpine|^[0-9]+\.[0-9]+\$|inline"
    "MySQL (federated)|library|mysql|^[0-9]+\.[0-9]+\$|inline"
    "PoolParty Keycloak|ontotext|poolparty-keycloak|^[0-9]+\.[0-9]+\.[0-9]+\$|skip"
)

# Maps HUB_IMAGE → primary values file (for standard/addon types)
primary_values_file() {
    case "$1" in
        poolparty)              echo "charts/poolparty/values.yaml" ;;
        graphdb)                echo "charts/graphdb/values.yaml" ;;
        poolparty-elasticsearch) echo "charts/poolparty-elasticsearch/values.yaml" ;;
        nginx)                  echo "charts/console/values.yaml" ;;
        adf)                    echo "charts/addons/charts/adf/values.yaml" ;;
        semantic-workbench)     echo "charts/addons/charts/semantic-workbench/values.yaml" ;;
        graphviews)             echo "charts/addons/charts/graphviews/values.yaml" ;;
        rdf4j-workbench)        echo "charts/addons/charts/rdf4j/values.yaml" ;;
        unifiedviews)           echo "charts/addons/charts/unifiedviews/values.yaml" ;;
        refine)                 echo "charts/addons/charts/refine/values.yaml" ;;
        alpine)                 echo "charts/graphwise-stack/values.yaml" ;;
        mysql)                  echo "charts/graphwise-stack/values.yaml" ;;
    esac
}

# Maps HUB_IMAGE → Chart.yaml path for appVersion update (empty = no update)
chart_yaml_for() {
    case "$1" in
        poolparty)              echo "charts/poolparty/Chart.yaml" ;;
        graphdb)                echo "charts/graphdb/Chart.yaml" ;;
        poolparty-elasticsearch) echo "charts/poolparty-elasticsearch/Chart.yaml" ;;
        *)                      echo "" ;;
    esac
}

# Read the current tag from a values file
read_current_tag() {
    local img="$1" type="$2"
    local vfile
    vfile=$(primary_values_file "$img")
    case "$type" in
        standard|addon)
            grep -m1 '^\s*tag:' "$vfile" | sed 's/.*tag: *"\(.*\)"/\1/'
            ;;
        inline)
            # e.g. `image: alpine:3.20` or `image: "mysql:9.7"` — keyed on the
            # hub image name so each inline image reads its own tag.
            grep -m1 "image:.*${img}:" "$vfile" | sed "s/.*${img}:\([^\"]*\).*/\1/" | tr -d '"'
            ;;
        skip)
            echo "latest (pinned)"
            ;;
    esac
}

# ─── Phase 1: collect current tags + fetch latest ────────────────────────────
echo ""
echo "${BOLD}${CYAN}Graphwise Stack — container image version check${RESET}"
echo "${DIM}Querying Docker Hub for latest tags…${RESET}"
echo ""

declare -a LABELS CURRENT_TAGS LATEST_TAGS STATUSES IMG_NAMES IMG_TYPES IMG_NS

for entry in "${IMAGES[@]}"; do
    IFS='|' read -r label ns img filter type <<< "$entry"

    current=$(read_current_tag "$img" "$type")

    if [ "$type" = "skip" ]; then
        latest="—"
        status="skip"
    else
        printf "  %-28s" "${label}..."
        latest=$(fetch_latest "$ns" "$img" "$filter")
        if [ -z "$latest" ]; then
            latest="?"
            status="error"
            echo "${RED}fetch failed${RESET}"
        elif [ "$current" = "$latest" ]; then
            status="ok"
            echo "${GREEN}${latest}${RESET} ✓"
        else
            status="update"
            echo "${YELLOW}${latest}${RESET} (current: ${current})"
        fi
    fi

    LABELS+=("$label")
    CURRENT_TAGS+=("$current")
    LATEST_TAGS+=("$latest")
    STATUSES+=("$status")
    IMG_NAMES+=("$img")
    IMG_TYPES+=("$type")
    IMG_NS+=("$ns")
done

# ─── Phase 2: display summary table ──────────────────────────────────────────
echo ""
echo "${BOLD}─── Summary ──────────────────────────────────────────────────────────────${RESET}"
printf "${BOLD}%-28s %-16s %-16s %s${RESET}\n" "Image" "Current" "Latest" "Status"
echo "─────────────────────────────────────────────────────────────────────────"
for i in "${!LABELS[@]}"; do
    case "${STATUSES[$i]}" in
        ok)     mark="${GREEN}✓ up-to-date${RESET}" ;;
        update) mark="${YELLOW}↑ update available${RESET}" ;;
        skip)   mark="${DIM}— pinned (latest)${RESET}" ;;
        error)  mark="${RED}? fetch failed${RESET}" ;;
    esac
    printf "%-28s %-16s %-16s %b\n" \
        "${LABELS[$i]}" "${CURRENT_TAGS[$i]}" "${LATEST_TAGS[$i]}" "$mark"
done
echo "─────────────────────────────────────────────────────────────────────────"

# Count updates
UPDATE_COUNT=0
for i in "${!STATUSES[@]}"; do
    [ "${STATUSES[$i]}" = "update" ] && UPDATE_COUNT=$((UPDATE_COUNT + 1))
done

if [ "$UPDATE_COUNT" -eq 0 ]; then
    echo ""
    echo "${GREEN}All images are up-to-date.${RESET}"
    exit 0
fi

echo ""
echo "${YELLOW}${UPDATE_COUNT} update(s) available.${RESET}"

# ─── Phase 3: interactive upgrade prompts ────────────────────────────────────
ANY_UPGRADED=0
NEEDS_DEP_UPDATE=0
UPGRADED_REFS=()   # full docker refs (repo:tag) accepted this run, for --apply

apply_standard_update() {
    local img="$1" old="$2" new="$3"
    local vfile
    vfile=$(primary_values_file "$img")
    sed_inplace "$vfile" "s/  tag: \"${old}\"/  tag: \"${new}\"/"

    local chart_yaml
    chart_yaml=$(chart_yaml_for "$img")
    if [ -n "$chart_yaml" ]; then
        sed_inplace "$chart_yaml" "s/appVersion: \"${old}\"/appVersion: \"${new}\"/"
        # Also update description text that mentions the version (best-effort)
        sed_inplace "$chart_yaml" "s|:${old},|:${new},|g"
    fi
    NEEDS_DEP_UPDATE=1
}

apply_addon_update() {
    local img="$1" old="$2" new="$3"
    local subchart_file
    subchart_file=$(primary_values_file "$img")
    # Update nested subchart values (2-space indent)
    sed_inplace "$subchart_file" "s/  tag: \"${old}\"/  tag: \"${new}\"/"
    # Update parent addons/values.yaml (4-space indent)
    sed_inplace "charts/addons/values.yaml" "s/    tag: \"${old}\"/    tag: \"${new}\"/"
    NEEDS_DEP_UPDATE=1
}

apply_inline_update() {
    local img="$1" old="$2" new="$3"
    local vfile
    vfile=$(primary_values_file "$img")
    # Update `image: <img>:X.Y` style in values.yaml
    sed_inplace "$vfile" "s/${img}:${old}/${img}:${new}/g"
    # alpine is also hardcoded in a Job template; other inline images are not.
    if [ "$img" = "alpine" ]; then
        local template="charts/graphwise-stack/templates/graphrag-vectors-index-job.yaml"
        if [ -f "$template" ]; then
            sed_inplace "$template" "s/alpine:${old}/alpine:${new}/g"
        fi
    fi
}

echo ""
for i in "${!LABELS[@]}"; do
    [ "${STATUSES[$i]}" != "update" ] && continue

    label="${LABELS[$i]}"
    old="${CURRENT_TAGS[$i]}"
    new="${LATEST_TAGS[$i]}"
    img="${IMG_NAMES[$i]}"
    type="${IMG_TYPES[$i]}"
    ns="${IMG_NS[$i]}"

    if [ "$AUTO_YES" -eq 1 ]; then
        answer="y"
    else
        printf "Upgrade ${BOLD}%-22s${RESET} %s → ${GREEN}%s${RESET}? [y/N] " \
            "$label" "$old" "$new"
        read -r answer || answer="n"
    fi

    case "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" in
        y|yes)
            case "$type" in
                standard) apply_standard_update "$img" "$old" "$new" ;;
                addon)    apply_addon_update    "$img" "$old" "$new" ;;
                inline)   apply_inline_update   "$img" "$old" "$new" ;;
            esac
            echo "  ${GREEN}✓${RESET} ${label} updated to ${new}"
            ANY_UPGRADED=1
            # Full docker ref the pod pulls: library/* is bare, else <ns>/<img>.
            if [ "$ns" = "library" ]; then
                UPGRADED_REFS+=("${img}:${new}")
            else
                UPGRADED_REFS+=("${ns}/${img}:${new}")
            fi
            ;;
        *)
            echo "  ${DIM}skipped${RESET}"
            ;;
    esac
done

# ─── Phase 4: rebuild tarballs if anything changed ───────────────────────────
if [ "$ANY_UPGRADED" -eq 0 ]; then
    echo ""
    echo "No upgrades applied."
    exit 0
fi

if [ "$NEEDS_DEP_UPDATE" -eq 1 ] && [ "$HAVE_HELM" -eq 1 ]; then
    echo ""
    echo "${CYAN}Rebuilding umbrella chart dependency tarballs…${RESET}"
    helm dependency update charts/graphwise-stack 2>&1 | grep -v "^$"
    echo "${GREEN}Done.${RESET}"
fi

# ─── Phase 5: (--apply) roll the live stack, non-destructively ───────────────
if [ "$APPLY" -eq 0 ]; then
    echo ""
    echo "Edits saved to ./charts. Re-run with ${BOLD}--apply${RESET} to roll the live stack in place,"
    echo "or ${DIM}git add -p && git commit${RESET} to persist the version bump."
    exit 0
fi

echo ""
echo "${BOLD}${CYAN}--apply: rolling the live stack to the new image(s)…${RESET}"

UMBRELLA_RELEASE="${UMBRELLA_RELEASE:-graphwise-stack}"
UMBRELLA_NS="${UMBRELLA_NAMESPACE:-graphwise}"
KIND_CLUSTER="${KIND_CLUSTER:-graphwise}"
VALUES_DIR="${VALUES_DIR:-$HOME/.graphwise-stack}"

# Preconditions -- fail clearly, leaving the (already-saved) chart edits in place.
for c in helm kubectl docker kind; do
    command -v "$c" &>/dev/null || { echo "${RED}ERROR${RESET}: --apply needs '$c' in PATH." >&2; exit 1; }
done
if ! helm status "$UMBRELLA_RELEASE" -n "$UMBRELLA_NS" &>/dev/null; then
    echo "${YELLOW}No deployed '$UMBRELLA_RELEASE' release in ns '$UMBRELLA_NS'.${RESET}" >&2
    echo "  Chart edits + tarballs are saved; run reset-helm.sh / deploy-stack.sh to install first." >&2
    exit 1
fi

# Locate the per-deployment umbrella values overlay (render-values.sh output).
OVERLAY=""
if [ -n "${GRAPHWISE_APEX:-}" ] && [ -f "$VALUES_DIR/values-${GRAPHWISE_APEX%%.*}.yaml" ]; then
    OVERLAY="$VALUES_DIR/values-${GRAPHWISE_APEX%%.*}.yaml"
else
    _overlays=()
    for m in "$VALUES_DIR"/values-*.yaml; do
        [ -f "$m" ] || continue
        case "$m" in *-graphrag.yaml) continue ;; esac
        _overlays+=("$m")
    done
    if [ "${#_overlays[@]}" -eq 1 ]; then
        OVERLAY="${_overlays[0]}"
    else
        echo "${RED}ERROR${RESET}: could not resolve a single umbrella values overlay in $VALUES_DIR (found ${#_overlays[@]})." >&2
        echo "  Set GRAPHWISE_APEX=<sub>.<base>, or ensure exactly one values-<sub>.yaml exists." >&2
        exit 1
    fi
fi
echo "  ${DIM}overlay:${RESET} $OVERLAY"

# 1) Pull each new image and load it into the KIND node's containerd, so the
#    roll never hits an on-demand pull failure (ImagePullBackOff).
echo ""
echo "  ${BOLD}Pulling new image(s) into KIND ('$KIND_CLUSTER')…${RESET}"
for ref in "${UPGRADED_REFS[@]}"; do
    printf "    %-44s " "$ref"
    if docker pull "$ref" >/dev/null 2>&1 && kind load docker-image "$ref" --name "$KIND_CLUSTER" >/dev/null 2>&1; then
        echo "${GREEN}loaded${RESET}"
    else
        echo "${RED}FAILED${RESET}"
        echo "${RED}ERROR${RESET}: could not pull/load $ref -- aborting before helm upgrade." >&2
        exit 1
    fi
done

# 2) Non-destructive helm upgrade, reusing the deployment's existing overlays.
#    The new default image tags come from the rebuilt subchart tarballs; the
#    overlays supply per-deployment hostnames/secrets. PVCs are retained.
F_FLAGS=(-f "charts/graphwise-stack/values.yaml" -f "$OVERLAY")
[ -f "$HOME/graphwise-secrets.yaml" ]      && F_FLAGS+=(-f "$HOME/graphwise-secrets.yaml")
[ -f "$VALUES_DIR/console-branding.yaml" ] && F_FLAGS+=(-f "$VALUES_DIR/console-branding.yaml")

echo ""
echo "  ${BOLD}helm upgrade $UMBRELLA_RELEASE (PVCs retained — in-place)…${RESET}"
if ! helm upgrade "$UMBRELLA_RELEASE" charts/graphwise-stack -n "$UMBRELLA_NS" "${F_FLAGS[@]}" --timeout "$HELM_TIMEOUT"; then
    echo "${RED}ERROR${RESET}: helm upgrade failed. Inspect: kubectl -n $UMBRELLA_NS get pods" >&2
    exit 1
fi

# 3) Wait for the affected workloads to roll (graphwise + graphdb namespaces).
echo ""
echo "  ${BOLD}Waiting for workloads to roll…${RESET}"
for ns_watch in "$UMBRELLA_NS" graphdb; do
    for r in $(kubectl -n "$ns_watch" get deploy,statefulset -o name 2>/dev/null); do
        kubectl -n "$ns_watch" rollout status "$r" --timeout=240s 2>/dev/null || true
    done
done

echo ""
echo "${GREEN}${BOLD}Live stack updated to the new image(s).${RESET}"
echo "  Verify:  ${DIM}kubectl get pods -A${RESET}"
echo "  ${DIM}Persist the chart edits for future rebuilds: git add -p && git commit${RESET}"
