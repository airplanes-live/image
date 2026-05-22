#!/usr/bin/env bash
# Build the runtime overlay assets for a unified product release.
#
# Produces:
#   <output-dir>/tree/v<VERSION>/...
#   <output-dir>/runtime-overlay-<arch>.tar.gz
#   <output-dir>/runtime-manifest.json
#   <output-dir>/runtime-PROVENANCE.md
#   <output-dir>/runtime-SHA256SUMS

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: build-runtime-assets.sh \
    --channel <stable|dev> \
    --version <version> \
    --commit-sha <40-hex> \
    --arch <arm64> \
    --output-dir <dir> \
    [--run-url <url>]
USAGE
}

die() {
    echo "build-runtime-assets: $*" >&2
    exit 1
}

_self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
overlay_dir="$(cd "$_self_dir/../.." && pwd)"

CHANNEL=""
VERSION=""
COMMIT_SHA=""
ARCH=""
OUTPUT_DIR=""
RUN_URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)    CHANNEL="${2-}";    shift 2 ;;
        --version)    VERSION="${2-}";    shift 2 ;;
        --commit-sha) COMMIT_SHA="${2-}"; shift 2 ;;
        --arch)       ARCH="${2-}";       shift 2 ;;
        --output-dir) OUTPUT_DIR="${2-}"; shift 2 ;;
        --run-url)    RUN_URL="${2-}";    shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage; die "unknown argument: $1" ;;
    esac
done

for required in CHANNEL VERSION COMMIT_SHA ARCH OUTPUT_DIR; do
    if [[ -z "${!required}" ]]; then
        flag="${required,,}"
        flag="${flag//_/-}"
        usage
        die "missing required --$flag"
    fi
done

case "$CHANNEL" in
    stable|dev) ;;
    *) die "--channel must be stable or dev (got: $CHANNEL)" ;;
esac

case "$ARCH" in
    arm64) ;;
    *) die "--arch must be arm64 (got: $ARCH)" ;;
esac

if ! [[ "$COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    die "--commit-sha must be 40 lowercase hex chars (got: $COMMIT_SHA)"
fi

install -d -m 0755 "$OUTPUT_DIR"

work_root="$(mktemp -d "${TMPDIR:-/tmp}/airplanes-runtime-assets.XXXXXXXX")"
trap 'rm -rf -- "$work_root"' EXIT

staging="$work_root/staging"
release_root="$OUTPUT_DIR/tree"
install -d -m 0755 "$staging" "$release_root"

set -a
# shellcheck disable=SC1090
. "$overlay_dir/config-$CHANNEL"
set +a

cp -- "$overlay_dir/manifest-inputs/managed_paths.json" \
      "$overlay_dir/manifest-inputs/mutable_paths.json" \
      "$overlay_dir/manifest-inputs/systemd.json" \
      "$overlay_dir/manifest-inputs/migrations.json" \
      "$overlay_dir/manifest-inputs/compat.json" \
      "$staging/"

bash "$overlay_dir/scripts/lib/cross-compile-readsb.sh" \
    --repo "$AIRPLANES_READSB_DECODER_REPO" \
    --ref "$AIRPLANES_READSB_DECODER_BRANCH" \
    --arch "$ARCH" \
    --output-dir "$staging"

bash "$overlay_dir/scripts/lib/cross-compile-dump978.sh" \
    --repo "$AIRPLANES_DUMP978_REPO" \
    --ref "$AIRPLANES_DUMP978_BRANCH" \
    --arch "$ARCH" \
    --output-dir "$staging"

bash "$overlay_dir/scripts/lib/stage-tar1090.sh" \
    --repo "$AIRPLANES_TAR1090_REPO" \
    --ref "$AIRPLANES_TAR1090_BRANCH" \
    --db-repo "$AIRPLANES_TAR1090_DB_REPO" \
    --db-ref "$AIRPLANES_TAR1090_DB_BRANCH" \
    --output-dir "$staging"

bash "$overlay_dir/scripts/lib/stage-graphs1090.sh" \
    --repo "$AIRPLANES_GRAPHS1090_REPO" \
    --ref "$AIRPLANES_GRAPHS1090_BRANCH" \
    --output-dir "$staging"

if [[ -d "$overlay_dir/src/share/airplanes" ]]; then
    mkdir -p "$staging/share/airplanes"
    cp -a "$overlay_dir/src/share/airplanes/." "$staging/share/airplanes/"
fi
if [[ -d "$overlay_dir/src/lib" ]]; then
    mkdir -p "$staging/lib"
    cp -a "$overlay_dir/src/lib/." "$staging/lib/"
fi
if [[ -d "$overlay_dir/src/systemd" ]]; then
    mkdir -p "$staging/systemd"
    cp -a "$overlay_dir/src/systemd/." "$staging/systemd/"
fi
if [[ -d "$overlay_dir/src/etc" ]]; then
    mkdir -p "$staging/etc"
    cp -a "$overlay_dir/src/etc/." "$staging/etc/"
fi

mkdir -p "$staging/migrations" "$staging/scripts/lib"
cp -a "$overlay_dir/scripts/lib/install-common.sh" \
    "$staging/scripts/lib/install-common.sh"

bash "$overlay_dir/scripts/lib/aggregate-components-json.sh" \
    --input-dir "$staging"

build_date="$(date -u --rfc-3339=seconds | sed 's/ /T/')"
bash "$overlay_dir/scripts/build-release.sh" \
    --arch "$ARCH" \
    --channel "$CHANNEL" \
    --version "$VERSION" \
    --commit-sha "$COMMIT_SHA" \
    --build-date "$build_date" \
    --input-dir "$staging" \
    --output-dir "$release_root"

release_dir="$release_root/v$VERSION"
bash "$overlay_dir/scripts/release-workflow/write-provenance.sh" \
    --release-dir "$release_dir" \
    --run-url "$RUN_URL"

tarball="$OUTPUT_DIR/runtime-overlay-$ARCH.tar.gz"
bash "$overlay_dir/scripts/release-workflow/pack-release-tarball.sh" \
    --release-dir "$release_dir" \
    --output "$tarball"

cp -- "$release_dir/manifest.json" "$OUTPUT_DIR/runtime-manifest.json"
cp -- "$release_dir/PROVENANCE.md" "$OUTPUT_DIR/runtime-PROVENANCE.md"

( cd "$release_dir" && sha256sum -c SHA256SUMS )

tmp_sums="$(mktemp "$OUTPUT_DIR/.runtime-SHA256SUMS.XXXXXX")"
(
    cd "$OUTPUT_DIR"
    sha256sum \
        "runtime-overlay-$ARCH.tar.gz" \
        runtime-manifest.json \
        runtime-PROVENANCE.md
) | LC_ALL=C sort -k2 > "$tmp_sums"
mv -f -- "$tmp_sums" "$OUTPUT_DIR/runtime-SHA256SUMS"

echo "build-runtime-assets: wrote $OUTPUT_DIR"
