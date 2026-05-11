#!/bin/bash
# Generate an rpi-imager Custom Repository manifest sidecar for an airplanes.live
# feeder image artifact (.img.xz). The manifest URL pasted into rpi-imager v2.0.8+
# enables the OS Customization (Edit Settings) flow via init_format=cloudinit-rpi.
#
# Usage: make-imager-manifest.sh [--image-url URL] PATH_TO_IMAGE.img.xz
#
# With --image-url, the manifest's `url` field is set to URL instead of a
# file:// URI of the local artifact. Use this in CI when the manifest will be
# served from a GitHub release and rpi-imager has to fetch over HTTPS.
# extract_size / extract_sha256 / image_download_size are still computed from
# the local .img.xz — those have to match the asset rpi-imager downloads from
# URL, so callers are responsible for keeping the two in sync.
#
# Output sibling file: ${input%.img.xz}.rpi-imager-manifest.json
set -euo pipefail

IMAGE_URL_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image-url)
            if [[ $# -lt 2 ]]; then
                echo "--image-url requires a URL argument" >&2
                exit 2
            fi
            IMAGE_URL_OVERRIDE="$2"
            shift 2
            ;;
        --image-url=*)
            IMAGE_URL_OVERRIDE="${1#--image-url=}"
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "unknown flag: $1" >&2
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -ne 1 ]]; then
    echo "usage: $(basename -- "$0") [--image-url URL] PATH_TO_IMAGE.img.xz" >&2
    exit 2
fi

if [[ -n "$IMAGE_URL_OVERRIDE" && "$IMAGE_URL_OVERRIDE" != *://* ]]; then
    echo "--image-url must be an absolute URL (scheme://...): $IMAGE_URL_OVERRIDE" >&2
    exit 2
fi

INPUT="$1"

if [[ ! -f "$INPUT" ]]; then
    echo "input not a regular file: $INPUT" >&2
    exit 1
fi

case "$INPUT" in
    *.img.xz) ;;
    *) echo "input must end in .img.xz: $INPUT" >&2; exit 1 ;;
esac

for cmd in jq xz sha256sum stat python3 date mktemp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "missing required tool: $cmd" >&2
        exit 1
    fi
done

INPUT_BASE="$(basename -- "$INPUT")"
# Filename convention: airplanes-feeder-${channel}-${arch}.img.xz
# (matches .github/workflows/build-image.yml IMG_NAME / ARCHIVE_FILENAME).
CHANNEL=""
case "$INPUT_BASE" in
    airplanes-feeder-dev-*.img.xz)    CHANNEL="dev" ;;
    airplanes-feeder-stable-*.img.xz) CHANNEL="stable" ;;
    *)
        echo "filename must match airplanes-feeder-{dev,stable}-*.img.xz: $INPUT_BASE" >&2
        exit 1
        ;;
esac

# Absolute path so file:// URI is dereferenceable from rpi-imager (which has no
# CWD-aware base). Resolve via python3 to avoid GNU-readlink portability churn
# and match the as_uri() call below.
INPUT_ABS="$(python3 -c 'import sys, pathlib; print(pathlib.Path(sys.argv[1]).resolve())' "$INPUT")"

OUTPUT="${INPUT_ABS%.img.xz}.rpi-imager-manifest.json"

# Drop any stale prior manifest before we start computing the new one. If the
# script fails mid-flight (xz error, sha256sum error, jq error), the worst case
# is "no manifest" rather than "stale manifest pointing at a different image".
# Atomic install of the new content via `.tmp.$$` + mv happens at the bottom.
rm -f -- "$OUTPUT"

# Compressed artifact size (file:// download size for rpi-imager).
IMAGE_DOWNLOAD_SIZE="$(stat -c %s -- "$INPUT_ABS")"

# Decompressed image size: read from `xz --robot --list` rather than
# decompressing twice. Column 5 of the `file` line is the uncompressed size in
# bytes (xz(1) man page, "The columns of the file lines"). A separate
# `xz -dc | wc -c` would re-decompress a multi-GB image; this is O(metadata).
EXTRACT_SIZE="$(xz --robot --list -- "$INPUT_ABS" | awk '$1 == "file" { print $5; exit }')"
if [[ -z "$EXTRACT_SIZE" || ! "$EXTRACT_SIZE" =~ ^[0-9]+$ ]]; then
    echo "could not read uncompressed size from xz --robot --list: $INPUT_ABS" >&2
    exit 1
fi

# Stream-hash the decompressed bytes (no temp .img file).
EXTRACT_SHA256="$(xz -dc -- "$INPUT_ABS" | sha256sum | cut -d' ' -f1)"
if [[ ! "$EXTRACT_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "sha256sum produced unexpected output: $EXTRACT_SHA256" >&2
    exit 1
fi

if [[ -n "$IMAGE_URL_OVERRIDE" ]]; then
    IMAGE_URI="$IMAGE_URL_OVERRIDE"
else
    # file:// URI from absolute path. pathlib.as_uri() handles spaces and non-ASCII
    # chars correctly (RFC 3986 percent-encoding) — bash printf does not.
    IMAGE_URI="$(python3 -c 'import sys, pathlib; print(pathlib.Path(sys.argv[1]).as_uri())' "$INPUT_ABS")"
fi

# Use the .img.xz mtime, not now(): the manifest follows the artifact, and
# multiple regenerations of the manifest for the same image should produce the
# same release_date.
RELEASE_DATE="$(date -u -r "$INPUT_ABS" +%Y-%m-%d)"

NAME="airplanes.live feeder (${CHANNEL})"
DESCRIPTION="airplanes.live ADS-B/MLAT/UAT feeder image (${CHANNEL} channel). Edit Settings to set WiFi, hostname, SSH key, and feeder claim secret before flashing."

# Tag list the OS entry advertises. arm64-only — this image is not built for
# 32-bit Pis. rpi-imager's filterOsListWithHWTags keeps an entry when any of
# its `devices` tags matches the user-selected device's tag set.
OS_DEVICE_TAGS_JSON='["pi5-64bit","pi4-64bit","pi3-64bit"]'

# Rich device entries for rpi-imager's device-selection screen. Mirrors
# upstream's os_list_imagingutility_v4.json shape (downloads.raspberrypi.com)
# so the screen renders Pi names, icons, and descriptions instead of empty
# rows. Restricted to arm64-capable Pis (Pi 3 / 4 / 5 / Zero 2 W) since this
# image only runs on those. "No filtering" mirrors upstream's escape hatch so
# the user can still see our entry if their Pi tag is unfamiliar.
IMAGER_DEVICES_JSON=$(cat <<'JSON'
[
  {
    "name": "Raspberry Pi 5",
    "tags": ["pi5-64bit", "pi5-32bit"],
    "icon": "https://downloads.raspberrypi.com/imager/icons/RPi_5.png",
    "description": "Raspberry Pi 5, 500 / 500+, and Compute Module 5",
    "matching_type": "exclusive",
    "capabilities": []
  },
  {
    "name": "Raspberry Pi 4",
    "tags": ["pi4-64bit", "pi4-32bit"],
    "icon": "https://downloads.raspberrypi.com/imager/icons/RPi_4.png",
    "description": "Raspberry Pi 4 Model B, 400, and Compute Module 4 / 4S",
    "matching_type": "inclusive",
    "capabilities": []
  },
  {
    "name": "Raspberry Pi 3",
    "tags": ["pi3-64bit", "pi3-32bit"],
    "icon": "https://downloads.raspberrypi.com/imager/icons/RPi_3.png",
    "description": "Raspberry Pi 3 Model A+ / B / B+ and Compute Module 3 / 3+",
    "matching_type": "inclusive",
    "capabilities": []
  },
  {
    "name": "Raspberry Pi Zero 2 W",
    "tags": ["pi3-64bit", "pi3-32bit"],
    "icon": "https://downloads.raspberrypi.com/imager/icons/RPi_Zero_2_W.png",
    "description": "Raspberry Pi Zero 2 W",
    "matching_type": "inclusive",
    "capabilities": []
  },
  {
    "name": "No filtering",
    "tags": [],
    "description": "Show every possible image",
    "matching_type": "inclusive",
    "capabilities": []
  }
]
JSON
)

# Same-directory mktemp keeps the final `mv` atomic (rename within one fs).
# Avoids predictable `$$`-based names that could conflict with a shared
# /tmp-style directory or be hijacked via symlink races.
TMP="$(mktemp -- "${OUTPUT}.tmp.XXXXXX")"
trap 'rm -f -- "$TMP"' EXIT INT TERM

jq -n \
    --arg name "$NAME" \
    --arg description "$DESCRIPTION" \
    --arg release_date "$RELEASE_DATE" \
    --arg url "$IMAGE_URI" \
    --argjson extract_size "$EXTRACT_SIZE" \
    --arg extract_sha256 "$EXTRACT_SHA256" \
    --argjson image_download_size "$IMAGE_DOWNLOAD_SIZE" \
    --argjson os_device_tags "$OS_DEVICE_TAGS_JSON" \
    --argjson imager_devices "$IMAGER_DEVICES_JSON" \
    '{
        imager: { devices: $imager_devices },
        os_list: [
            {
                name: $name,
                description: $description,
                icon: "",
                release_date: $release_date,
                init_format: "cloudinit-rpi",
                url: $url,
                extract_size: $extract_size,
                extract_sha256: $extract_sha256,
                image_download_size: $image_download_size,
                devices: $os_device_tags,
                capabilities: []
            }
        ]
    }' > "$TMP"

chmod 0644 "$TMP"
mv -f -- "$TMP" "$OUTPUT"
trap - EXIT INT TERM

# file:// URI of the manifest itself — this is what the user pastes into
# rpi-imager > Choose OS > Custom Repository.
MANIFEST_URI="$(python3 -c 'import sys, pathlib; print(pathlib.Path(sys.argv[1]).as_uri())' "$OUTPUT")"

echo "OK: $OUTPUT"
echo "rpi-imager Custom Repository URL: $MANIFEST_URI"
