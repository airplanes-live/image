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
# This script downloads these assets, verifies SHA256, and extracts them into
# the overlay staging tree so they ship as managed_paths entries in the runtime
# overlay release.
#
# Commit-SHA gate (opt-in). When --commit-sha is supplied (stable channel), the
# manifest's commit_sha must equal it or the build hard-fails — the fixed pin is
# stable's provenance anchor and keeps the build reproducible. When it is omitted
# (dev channel, which tracks the moving dev-latest tag), the manifest's own
# commit_sha is trusted and recorded. That trusts the release manifest plus the
# *same release's* SHA256SUMS — i.e. the assets are internally consistent with
# each other, not an independent provenance boundary. The SHA256SUMS integrity
# check below runs in both cases regardless.
#
# Args:
#   --release-tag <tag>        GitHub release tag (e.g. dev-latest, v0.1.2)
#   --commit-sha <40-hex>      expected commit_sha (optional; when omitted the
#                              manifest's own commit_sha is used — see below)
#   --arch <arm64>             target architecture
#   --output-dir <staging>     per-arch staging dir to populate
#   --download-base <url>      base URL for release assets (optional; for tests)
#
# On success:
#   <output-dir>/bin/airplanes-webconfig                        binary
#   <output-dir>/bin/apl-aggregator                             helper
#   <output-dir>/lib/airplanes-webconfig/...                    helpers (incl.
#                                                               aggregator-run +
#                                                               aggregators/*.desc)
#   <output-dir>/lib/airplanes/wifi-validators.sh               wifi lib
#   <output-dir>/lib/airplanes/wifi-keyfile.sh                  wifi lib
#   <output-dir>/systemd/airplanes-webconfig.service            unit
#   <output-dir>/systemd/airplanes-webconfig-reset.service      unit
#   <output-dir>/systemd/airplanes-aggregator@.service          unit
#   <output-dir>/etc/sudoers.d/010_airplanes-webconfig          sudoers
#   <output-dir>/etc/lighttpd/conf-available/40-airplanes-webconfig.conf
#   <output-dir>/components.webconfig.sha                       commit SHA
#   <output-dir>/components.webconfig.version                   version string

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: stage-webconfig.sh \
    --release-tag <tag> \
    --arch <arm64> \
    --output-dir <staging> \
    [--commit-sha <40-hex>] \
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

for required in RELEASE_TAG ARCH OUTPUT_DIR; do
    if [[ -z "${!required}" ]]; then
        flag="${required,,}"
        flag="${flag//_/-}"
        usage
        die "missing required --$flag"
    fi
done

# --commit-sha is optional. When supplied it must be a 40-hex pin; when omitted
# the manifest's own commit_sha is adopted after SHA256 verification.
if [[ -n "$COMMIT_SHA" ]] && ! [[ "$COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    die "--commit-sha must be 40 lowercase hex chars (got: $COMMIT_SHA)"
fi

case "$ARCH" in
    arm64) ;;
    *) die "--arch must be arm64 (got: $ARCH)" ;;
esac

: "${DOWNLOAD_BASE:=https://github.com/airplanes-live/image-webconfig/releases/download}"

# Transient-download resilience. dev-latest is a moving prerelease: while the
# publisher force-moves the tag and re-uploads assets, a fetch can briefly race
# a missing or half-published asset (HTTP 404) or a mirror hiccup. Retry a few
# times with linear backoff so that window does not fail the whole build, while
# a genuine, persistent failure still surfaces. Overridable for tests.
: "${STAGE_WEBCONFIG_DL_ATTEMPTS:=5}"
: "${STAGE_WEBCONFIG_DL_BACKOFF:=3}"
[[ "$STAGE_WEBCONFIG_DL_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] \
    || die "STAGE_WEBCONFIG_DL_ATTEMPTS must be a positive integer (got: $STAGE_WEBCONFIG_DL_ATTEMPTS)"
[[ "$STAGE_WEBCONFIG_DL_BACKOFF" =~ ^[0-9]+$ ]] \
    || die "STAGE_WEBCONFIG_DL_BACKOFF must be a non-negative integer (got: $STAGE_WEBCONFIG_DL_BACKOFF)"

fetch_asset() {
    local url="$1" dest="$2" attempt=1
    while :; do
        if curl -fsSL --max-time 120 -o "$dest" "$url"; then
            return 0
        fi
        if (( attempt >= STAGE_WEBCONFIG_DL_ATTEMPTS )); then
            return 1
        fi
        echo "stage-webconfig: fetch attempt ${attempt}/${STAGE_WEBCONFIG_DL_ATTEMPTS} failed; retrying in ${STAGE_WEBCONFIG_DL_BACKOFF}s: $url" >&2
        sleep "$STAGE_WEBCONFIG_DL_BACKOFF"
        attempt=$(( attempt + 1 ))
    done
}

work="$(mktemp -d "${TMPDIR:-/tmp}/stage-webconfig.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT

# --- download ----------------------------------------------------------------

base_url="${DOWNLOAD_BASE}/${RELEASE_TAG}"

binary_name="airplanes-webconfig-${ARCH}"
for asset in "$binary_name" rootfs.tar.gz manifest.json SHA256SUMS; do
    echo "stage-webconfig: downloading $asset"
    if ! fetch_asset "$base_url/$asset" "$work/$asset"; then
        die "download failed after ${STAGE_WEBCONFIG_DL_ATTEMPTS} attempts: $base_url/$asset"
    fi
done

# --- verify SHA256 -----------------------------------------------------------
# The published SHA256SUMS lists every arch binary (arm64 + armhf), but we
# only download the binary for our target arch plus the arch-independent
# rootfs/manifest. Filter the checksum list to just the assets present so
# `sha256sum -c` doesn't fail on the other arch's missing file.
grep -E "  (${binary_name}|rootfs\.tar\.gz|manifest\.json)\$" \
    "$work/SHA256SUMS" > "$work/SHA256SUMS.expected"
expected_lines="$(wc -l < "$work/SHA256SUMS.expected")"
if [[ "$expected_lines" -ne 3 ]]; then
    die "SHA256SUMS missing one of $binary_name / rootfs.tar.gz / manifest.json (matched $expected_lines)"
fi
(cd "$work" && sha256sum -c SHA256SUMS.expected) || die "SHA256 verification failed"

# --- verify manifest commit_sha ----------------------------------------------

manifest_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit_sha",""))' "$work/manifest.json")"
if [[ -z "$manifest_sha" ]]; then
    die "manifest.json missing commit_sha field"
fi
if ! [[ "$manifest_sha" =~ ^[0-9a-f]{40}$ ]]; then
    die "manifest.json commit_sha must be 40 lowercase hex chars (got: $manifest_sha)"
fi
if [[ -n "$COMMIT_SHA" ]]; then
    # Pinned (stable): the manifest must match the supplied pin.
    if [[ "$manifest_sha" != "$COMMIT_SHA" ]]; then
        die "manifest commit_sha=$manifest_sha does not match expected=$COMMIT_SHA"
    fi
else
    # Unpinned (dev): adopt the manifest's own commit_sha so the recorded
    # component pin still reflects the real commit that was staged.
    COMMIT_SHA="$manifest_sha"
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

# apl-aggregator helper → overlay bin/. Its run-helper (aggregator-run) and the
# adapter descriptors under aggregators/ already arrive via the
# lib/airplanes-webconfig/ copy above. managed_paths.json exposes aggregators/
# as a single directory symlink, so new descriptors (e.g. a future adapter)
# ship automatically with no manifest change — and conversely must NOT be added
# as per-file managed_paths under that directory (a child symlink would be
# created through the parent symlink into the release tree).
if [[ -f "$rootfs/usr/local/bin/apl-aggregator" ]]; then
    install -m 0755 "$rootfs/usr/local/bin/apl-aggregator" "$OUTPUT_DIR/bin/apl-aggregator"
fi

# WiFi libs → overlay lib/airplanes/
install -d -m 0755 "$OUTPUT_DIR/lib/airplanes"
for lib in wifi-validators.sh wifi-keyfile.sh; do
    if [[ -f "$rootfs/usr/local/lib/airplanes/$lib" ]]; then
        install -m 0644 "$rootfs/usr/local/lib/airplanes/$lib" "$OUTPUT_DIR/lib/airplanes/$lib"
    fi
done

# Systemd units → overlay systemd/. airplanes-aggregator@.service is a template
# enabled per-instance at runtime by apl-aggregator, so it is deliberately not
# in systemd.json's enable list. An overlay self-update lands a changed template
# or run-helper but does not restart already-running aggregator instances (the
# update restart pass only touches enabled units); they pick up changes on the
# next enable/disable or reboot — acceptable for non-critical external feeders.
install -d -m 0755 "$OUTPUT_DIR/systemd"
for unit in airplanes-webconfig.service airplanes-webconfig-reset.service \
            airplanes-aggregator@.service; do
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
