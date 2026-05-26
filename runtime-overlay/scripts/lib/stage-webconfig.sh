#!/usr/bin/env bash
# stage-webconfig.sh — download the airplanes-live/image-webconfig GitHub
# release and stage its artifacts into the runtime-overlay build tree.
#
# The webconfig release publishes:
#   airplanes-webconfig-<arch>    prebuilt Go binary
#   rootfs.tar.gz                 FHS payload (sudoers, systemd units, helpers)
#   manifest.json                 {version, commit_sha, ...}
#   SHA256SUMS                    integrity checksums for all of the above
#
# This script downloads these assets, verifies SHA256, cross-checks the
# manifest commit_sha against a resolved pin, and extracts them into the
# overlay staging tree so they ship as managed_paths entries in the runtime
# overlay release.
#
# Args:
#   --release-tag <tag>        GitHub release tag (e.g. dev-latest, v0.1.2)
#   --commit-sha <40-hex>      expected commit_sha from the resolved pin
#   --arch <arm64>             target architecture
#   --output-dir <staging>     per-arch staging dir to populate
#   --download-base <url>      base URL for release assets (optional; for tests)
#
# On success:
#   <output-dir>/bin/airplanes-webconfig                        binary
#   <output-dir>/lib/airplanes-webconfig/...                    helpers
#   <output-dir>/lib/airplanes/wifi-validators.sh               wifi lib
#   <output-dir>/lib/airplanes/wifi-keyfile.sh                  wifi lib
#   <output-dir>/systemd/airplanes-webconfig.service            unit
#   <output-dir>/systemd/airplanes-webconfig-reset.service      unit
#   <output-dir>/etc/sudoers.d/010_airplanes-webconfig          sudoers
#   <output-dir>/etc/lighttpd/conf-available/40-airplanes-webconfig.conf
#   <output-dir>/components.webconfig.sha                       commit SHA
#   <output-dir>/components.webconfig.version                   version string

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: stage-webconfig.sh \
    --release-tag <tag> \
    --commit-sha <40-hex> \
    --arch <arm64> \
    --output-dir <staging> \
    [--download-base <url>]
USAGE
}

die() {
    echo "stage-webconfig: $*" >&2
    exit 1
}

RELEASE_TAG=""
COMMIT_SHA=""
ARCH=""
OUTPUT_DIR=""
DOWNLOAD_BASE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release-tag)    RELEASE_TAG="${2-}";    shift 2 ;;
        --commit-sha)     COMMIT_SHA="${2-}";     shift 2 ;;
        --arch)           ARCH="${2-}";           shift 2 ;;
        --output-dir)     OUTPUT_DIR="${2-}";     shift 2 ;;
        --download-base)  DOWNLOAD_BASE="${2-}";  shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage; die "unknown argument: $1" ;;
    esac
done

for required in RELEASE_TAG COMMIT_SHA ARCH OUTPUT_DIR; do
    if [[ -z "${!required}" ]]; then
        flag="${required,,}"
        flag="${flag//_/-}"
        usage
        die "missing required --$flag"
    fi
done

if ! [[ "$COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    die "--commit-sha must be 40 lowercase hex chars (got: $COMMIT_SHA)"
fi

case "$ARCH" in
    arm64) ;;
    *) die "--arch must be arm64 (got: $ARCH)" ;;
esac

: "${DOWNLOAD_BASE:=https://github.com/airplanes-live/image-webconfig/releases/download}"

work="$(mktemp -d "${TMPDIR:-/tmp}/stage-webconfig.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT

# --- download ----------------------------------------------------------------

base_url="${DOWNLOAD_BASE}/${RELEASE_TAG}"

binary_name="airplanes-webconfig-${ARCH}"
for asset in "$binary_name" rootfs.tar.gz manifest.json SHA256SUMS; do
    echo "stage-webconfig: downloading $asset"
    if ! curl -fsSL --max-time 120 -o "$work/$asset" "$base_url/$asset"; then
        die "download failed: $base_url/$asset"
    fi
done

# --- verify SHA256 -----------------------------------------------------------

(cd "$work" && sha256sum -c SHA256SUMS) || die "SHA256 verification failed"

# --- verify manifest commit_sha ----------------------------------------------

manifest_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit_sha",""))' "$work/manifest.json")"
if [[ -z "$manifest_sha" ]]; then
    die "manifest.json missing commit_sha field"
fi
if [[ "$manifest_sha" != "$COMMIT_SHA" ]]; then
    die "manifest commit_sha=$manifest_sha does not match expected=$COMMIT_SHA"
fi

manifest_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$work/manifest.json")"
if [[ -z "$manifest_version" ]]; then
    die "manifest.json missing version field"
fi

# --- stage binary ------------------------------------------------------------

install -d -m 0755 "$OUTPUT_DIR/bin"
install -m 0755 "$work/$binary_name" "$OUTPUT_DIR/bin/airplanes-webconfig"

# --- stage rootfs payload ----------------------------------------------------
# Extract the rootfs tarball into a temporary tree, then redistribute its
# contents into the overlay staging layout.

rootfs="$work/rootfs"
install -d -m 0755 "$rootfs"
tar -xzf "$work/rootfs.tar.gz" -C "$rootfs"

# Helpers under /usr/local/lib/airplanes-webconfig/ → overlay lib/airplanes-webconfig/
if [[ -d "$rootfs/usr/local/lib/airplanes-webconfig" ]]; then
    install -d -m 0755 "$OUTPUT_DIR/lib/airplanes-webconfig"
    cp -a "$rootfs/usr/local/lib/airplanes-webconfig/." "$OUTPUT_DIR/lib/airplanes-webconfig/"
fi

# apl-wifi binary → overlay bin/
if [[ -f "$rootfs/usr/local/bin/apl-wifi" ]]; then
    install -m 0755 "$rootfs/usr/local/bin/apl-wifi" "$OUTPUT_DIR/bin/apl-wifi"
fi

# WiFi libs → overlay lib/airplanes/
install -d -m 0755 "$OUTPUT_DIR/lib/airplanes"
for lib in wifi-validators.sh wifi-keyfile.sh; do
    if [[ -f "$rootfs/usr/local/lib/airplanes/$lib" ]]; then
        install -m 0644 "$rootfs/usr/local/lib/airplanes/$lib" "$OUTPUT_DIR/lib/airplanes/$lib"
    fi
done

# Systemd units → overlay systemd/
install -d -m 0755 "$OUTPUT_DIR/systemd"
for unit in airplanes-webconfig.service airplanes-webconfig-reset.service; do
    if [[ -f "$rootfs/etc/systemd/system/$unit" ]]; then
        install -m 0644 "$rootfs/etc/systemd/system/$unit" "$OUTPUT_DIR/systemd/$unit"
    fi
done

# Sudoers → overlay etc/sudoers.d/ (copy-mode target in managed_paths)
install -d -m 0755 "$OUTPUT_DIR/etc/sudoers.d"
if [[ -f "$rootfs/etc/sudoers.d/010_airplanes-webconfig" ]]; then
    install -m 0440 "$rootfs/etc/sudoers.d/010_airplanes-webconfig" \
        "$OUTPUT_DIR/etc/sudoers.d/010_airplanes-webconfig"
fi

# --- component pin -----------------------------------------------------------

printf '%s' "$COMMIT_SHA" > "$OUTPUT_DIR/components.webconfig.sha"
printf '%s' "$manifest_version" > "$OUTPUT_DIR/components.webconfig.version"

echo "stage-webconfig: staged webconfig $manifest_version (sha=$COMMIT_SHA)"
