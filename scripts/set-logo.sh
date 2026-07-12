#!/usr/bin/env bash
# scripts/set-logo.sh <image-file> [customer-name]
#   Base64-encodes a customer logo into a persistent, gitignored Helm overlay
#   ($HOME/.graphwise-stack/console-branding.yaml) so the console landing-page
#   header shows it. reset-helm.sh includes the overlay automatically when present.
#   Run with --clear to remove branding and revert to the unbranded header.
set -euo pipefail

VALUES_DIR="${VALUES_DIR:-$HOME/.graphwise-stack}"
BRANDING_OVERLAY="$VALUES_DIR/console-branding.yaml"

usage() {
  echo "Usage: $0 <image-file.(png|jpg|jpeg|gif|svg)> [customer-name]"
  echo "       $0 --clear    # remove branding, revert to unbranded header"
  exit 1
}

[[ $# -ge 1 ]] || usage

if [[ "$1" == "--clear" ]]; then
  rm -f "$BRANDING_OVERLAY"
  echo "Removed $BRANDING_OVERLAY -- header renders unbranded on next deploy."
  exit 0
fi

IMG="$1"
NAME="${2:-$(basename "$IMG")}"
NAME_YAML="${NAME//\"/\\\"}"   # escape double-quotes so the YAML scalar stays valid
[[ -f "$IMG" ]] || { echo "ERROR: file not found: $IMG" >&2; exit 1; }

ext="$(printf '%s' "${IMG##*.}" | tr '[:upper:]' '[:lower:]')"
case "$ext" in
  png)       mime="image/png" ;;
  jpg|jpeg)  mime="image/jpeg" ;;
  gif)       mime="image/gif" ;;
  svg)       mime="image/svg+xml" ;;
  *) echo "ERROR: unsupported extension '.$ext' (use png/jpg/jpeg/gif/svg)" >&2; exit 1 ;;
esac

# Resize raster images to fit within 440×112 px (2× the CSS max-height:56/max-width:220
# so it renders crisply on retina displays without shipping a multi-MB source image).
# SVGs are vector and scale natively — skip them.
RESIZED_IMG="$IMG"
if [[ "$ext" != "svg" ]]; then
  orig_bytes=$(wc -c < "$IMG" | tr -d ' ')
  TMPIMG=$(mktemp "/tmp/gw-logo-resize.XXXXXX.${ext}")
  trap 'rm -f "$TMPIMG"' EXIT
  resized=no
  if command -v convert >/dev/null 2>&1; then
    convert "$IMG" -resize 440x112 "$TMPIMG"
    resized=yes; tool="ImageMagick"
  elif command -v sips >/dev/null 2>&1; then
    cp "$IMG" "$TMPIMG"
    sips -Z 440 "$TMPIMG" >/dev/null 2>&1 || true
    cur_h=$(sips -g pixelHeight "$TMPIMG" 2>/dev/null | awk '/pixelHeight/{print $2+0}')
    [ "${cur_h:-0}" -gt 112 ] && sips --resampleHeight 112 "$TMPIMG" >/dev/null 2>&1 || true
    resized=yes; tool="sips"
  else
    echo "WARNING: neither 'convert' (ImageMagick) nor 'sips' found; skipping resize." >&2
    echo "         Install: dnf install ImageMagick  (AL2023)  or  brew install imagemagick  (macOS)" >&2
  fi
  if [[ "$resized" == "yes" ]]; then
    new_bytes=$(wc -c < "$TMPIMG" | tr -d ' ')
    echo "Resized to fit 440×112 px (${tool}): ${orig_bytes} → ${new_bytes} bytes."
    RESIZED_IMG="$TMPIMG"
  fi
fi

# base64 with no newlines, portable across GNU (base64 -w0) and BSD/macOS.
b64="$(base64 < "$RESIZED_IMG" | tr -d '\n')"
bytes=${#b64}
if (( bytes > 262144 )); then
  echo "WARNING: encoded logo is ${bytes} bytes (>256KB). ConfigMaps cap at 1MB;" >&2
  echo "         a large logo bloats the console ConfigMap -- prefer a small PNG/SVG." >&2
fi

mkdir -p "$VALUES_DIR"
cat > "$BRANDING_OVERLAY" <<EOF
# Written by scripts/set-logo.sh -- customer logo for the console header.
# Gitignored, EC2-local. Delete this file (or run set-logo.sh --clear) to revert.
console:
  branding:
    logoDataUri: "data:${mime};base64,${b64}"
    logoAlt: "${NAME_YAML}"
EOF

echo "Wrote $BRANDING_OVERLAY (logo: $IMG, alt: \"$NAME\", ${bytes} base64 bytes)."
echo "Apply it:"
echo "  reset-helm.sh <sub> <base>     # full reinstall picks it up automatically, or"
echo "  helm upgrade graphwise-stack charts/graphwise-stack -n graphwise --reuse-values -f \"$BRANDING_OVERLAY\""
