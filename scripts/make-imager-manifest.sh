#!/bin/bash
# Generate an rpi-imager Custom Repository manifest sidecar for an airplanes.live
# feeder image artifact (.img.xz). The manifest URL pasted into rpi-imager v2.0.8+
# enables the OS Customization (Edit Settings) flow via init_format=cloudinit-rpi.
#
# Usage: make-imager-manifest.sh PATH_TO_IMAGE.img.xz
#
# Output sibling file: ${input%.img.xz}.rpi-imager-manifest.json
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $(basename -- "$0") PATH_TO_IMAGE.img.xz" >&2
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

for cmd in jq xz sha256sum stat python3 date wc; do
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

# file:// URI from absolute path. pathlib.as_uri() handles spaces and non-ASCII
# chars correctly (RFC 3986 percent-encoding) — bash printf does not.
IMAGE_URI="$(python3 -c 'import sys, pathlib; print(pathlib.Path(sys.argv[1]).as_uri())' "$INPUT_ABS")"

# Use the .img.xz mtime, not now(): the manifest follows the artifact, and
# multiple regenerations of the manifest for the same image should produce the
# same release_date.
RELEASE_DATE="$(date -u -r "$INPUT_ABS" +%Y-%m-%d)"

NAME="airplanes.live feeder (${CHANNEL})"
DESCRIPTION="airplanes.live ADS-B/MLAT/UAT feeder image (${CHANNEL} channel). Edit Settings to set WiFi, hostname, SSH key, and feeder claim secret before flashing."

# Pi 3 / 4 / 5 (64-bit). rpi-imager filters the os_list with the connected
# device's id; both blocks must agree (the top-level `imager.devices` is what
# the Custom Repository fetcher reads to decide whether this manifest is
# relevant for the connected device, the per-entry `devices` is what the OS
# entry advertises).
DEVICES_JSON='["pi5-64bit","pi4-64bit","pi3-64bit"]'

TMP="${OUTPUT}.tmp.$$"
trap 'rm -f -- "$TMP"' EXIT INT TERM

jq -n \
    --arg name "$NAME" \
    --arg description "$DESCRIPTION" \
    --arg release_date "$RELEASE_DATE" \
    --arg url "$IMAGE_URI" \
    --argjson extract_size "$EXTRACT_SIZE" \
    --arg extract_sha256 "$EXTRACT_SHA256" \
    --argjson image_download_size "$IMAGE_DOWNLOAD_SIZE" \
    --argjson devices "$DEVICES_JSON" \
    '{
        imager: { devices: $devices },
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
                devices: $devices,
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
