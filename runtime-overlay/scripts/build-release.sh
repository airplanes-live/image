#!/usr/bin/env bash
# build-release.sh — assemble a runtime-overlay release tree from a
# pre-staged input directory.
#
# This script does NOT build any components itself. It consumes a directory
# that some upstream step (manual layout for now; in CI, a component-builder
# script in a follow-up change) has populated with the FHS subdirs that ship
# in a release (bin/, lib/airplanes/, share/airplanes/, share/tar1090/,
# share/graphs1090/, systemd/, etc/, migrations/) plus a set of JSON
# snippets describing the dynamic pieces of the manifest. It produces:
#
#   <output-dir>/v<version>/...content copied from input-dir...
#   <output-dir>/v<version>/manifest.json
#   <output-dir>/v<version>/SHA256SUMS
#
# The output is byte-deterministic across runs given identical input bytes
# and the same --build-date, which is what makes runtime-release artifacts
# reproducible.
#
# Args (all required unless noted):
#   --arch <arm64>
#   --channel <stable|dev>
#   --version <semver>            (validated by the manifest schema)
#   --commit-sha <40-hex>
#   --input-dir <pre-staged-tree>
#   --output-dir <where-to-write-release-tree>
#   --build-date <RFC3339>        optional; defaults to current UTC RFC3339
#
# Exits 0 on success, non-zero on any validation or composition failure.

set -euo pipefail

_self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# shellcheck source=lib/manifest-render.sh
. "$_self_dir/lib/manifest-render.sh"

VALIDATE_MANIFEST="$_self_dir/validate-manifest.sh"

usage() {
    cat >&2 <<'USAGE'
usage: build-release.sh \
    --arch <arm64> \
    --channel <stable|dev> \
    --version <semver> \
    --commit-sha <40-hex> \
    --input-dir <pre-staged-tree> \
    --output-dir <where-to-write-release-tree> \
    [--build-date <RFC3339>]
USAGE
}

die() {
    echo "build-release: $*" >&2
    exit 1
}

# Subdirs that the schema's golden example references — the input tree must
# carry these so the staging step downstream has something to package. Empty
# subdirs are fine (the component builders that land in a follow-up change
# may legitimately produce empty trees on a host where the corresponding
# upstream installer is path-relocatability-gated).
REQUIRED_INPUT_SUBDIRS=(
    bin
    etc
    lib/airplanes
    migrations
    share/airplanes
    share/graphs1090
    share/tar1090
    systemd
)

# --- argument parsing ------------------------------------------------------

ARCH=""
CHANNEL=""
VERSION=""
COMMIT_SHA=""
INPUT_DIR=""
OUTPUT_DIR=""
BUILD_DATE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)        ARCH="${2-}";        shift 2 ;;
        --channel)     CHANNEL="${2-}";     shift 2 ;;
        --version)     VERSION="${2-}";     shift 2 ;;
        --commit-sha)  COMMIT_SHA="${2-}";  shift 2 ;;
        --input-dir)   INPUT_DIR="${2-}";   shift 2 ;;
        --output-dir)  OUTPUT_DIR="${2-}";  shift 2 ;;
        --build-date)  BUILD_DATE="${2-}";  shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage; die "unknown argument: $1" ;;
    esac
done

for required in ARCH CHANNEL VERSION COMMIT_SHA INPUT_DIR OUTPUT_DIR; do
    if [[ -z "${!required}" ]]; then
        flag="${required,,}"
        flag="${flag//_/-}"
        usage
        die "missing required --$flag"
    fi
done

# --- argument validation ---------------------------------------------------

case "$ARCH" in
    arm64) ;;
    armhf) die "--arch armhf is rejected; runtime overlay is arm64-only at v1" ;;
    *)     die "--arch must be arm64 (got: $ARCH)" ;;
esac

case "$CHANNEL" in
    stable|dev) ;;
    *) die "--channel must be stable or dev (got: $CHANNEL)" ;;
esac

# Version pattern mirrors the schema's. We don't re-derive it: the schema is
# the source of truth and validate-manifest.sh runs it later. The lexical
# pre-check here exists so an obviously-malformed --version fails fast with a
# legible diagnostic instead of a schema-error cascade. The schema also
# enforces a channel↔version pairing rule (dev → `-dev-YYYYMMDD-<sha>`,
# stable → no suffix); we leave that to the schema gate at the end.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-dev-[0-9]{8}-[0-9a-f]{7,40})?$ ]]; then
    die "--version is not a valid release version (got: $VERSION). Expected semver or '<semver>-dev-YYYYMMDD-<short-sha>'."
fi

if ! [[ "$COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    die "--commit-sha must be 40 lowercase hex chars (got: $COMMIT_SHA)"
fi

if [[ ! -d "$INPUT_DIR" ]]; then
    die "--input-dir not found or not a directory: $INPUT_DIR"
fi

# Reject an empty input-dir early — a downstream consumer would just fail
# more cryptically when the manifest packages nothing.
if [[ -z "$(find "$INPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    die "--input-dir is empty: $INPUT_DIR"
fi

for sub in "${REQUIRED_INPUT_SUBDIRS[@]}"; do
    if [[ ! -d "$INPUT_DIR/$sub" ]]; then
        die "--input-dir missing required subdirectory: $sub"
    fi
done

if [[ -z "$BUILD_DATE" ]]; then
    # RFC3339 in UTC, second precision. `date --rfc-3339=seconds` uses a
    # space separator; flip it to the canonical 'T' so the timestamp is the
    # one RFC3339 form jsonschema's date-time format checker recognises.
    BUILD_DATE="$(date -u --rfc-3339=seconds | sed 's/ /T/')"
fi

if [[ ! -x "$VALIDATE_MANIFEST" ]]; then
    die "manifest validator not found or not executable: $VALIDATE_MANIFEST"
fi

# --- composition -----------------------------------------------------------

RELEASE_DIR="$OUTPUT_DIR/v$VERSION"

# Refuse to clobber. A previous build at the same version dir is almost
# always a mistake — either the version got bumped wrong or the prior tree
# is still in use. The caller can `rm -rf` themselves if they actually mean
# it.
if [[ -e "$RELEASE_DIR" ]]; then
    die "release dir already exists: $RELEASE_DIR (remove it first or bump --version)"
fi

mkdir -p -- "$RELEASE_DIR"

# Copy the input tree into the release dir. `cp -a` preserves modes,
# ownership and timestamps; for determinism we don't actually need
# timestamps preserved (SHA256SUMS doesn't care) but preserving them also
# does no harm and matches what the on-device installer expects after
# untar.
cp -a -- "$INPUT_DIR/." "$RELEASE_DIR/"

# Strip the JSON-snippet inputs out of the release tree. They are manifest
# build-time inputs, not on-device assets, and the release dir on a feeder
# must not contain them.
for snippet in components managed_paths mutable_paths systemd migrations compat; do
    rm -f -- "$RELEASE_DIR/$snippet.json"
done

# Compose manifest.json. The renderer is responsible for canonical key
# ordering (jq -S) and atomic write.
airplanes_runtime_render_manifest \
    "$VERSION" \
    "$CHANNEL" \
    "$COMMIT_SHA" \
    "$BUILD_DATE" \
    "$ARCH" \
    "$INPUT_DIR" \
    "$RELEASE_DIR/manifest.json"

# Build SHA256SUMS over every file in the release dir EXCEPT SHA256SUMS
# itself. Sort with NUL separators under the C locale so the ordering is
# reproducible regardless of LANG/LC_COLLATE. Paths are emitted relative to
# the release dir so a `sha256sum -c` invocation inside that dir verifies
# cleanly.
SUMS_TMP="$(mktemp "$RELEASE_DIR/.SHA256SUMS.tmp.XXXXXX")"
# shellcheck disable=SC2064
trap 'rm -f -- "$SUMS_TMP"' EXIT

# Subshell to localize the CWD shift; the trap above still fires on exit.
# `find -printf '%P\0'` strips the leading "./" cleanly so the generated
# SHA256SUMS contains release-dir-relative paths without any post-processing.
(
    cd "$RELEASE_DIR"
    LC_ALL=C find . -type f \
        ! -name SHA256SUMS \
        ! -name '.SHA256SUMS.tmp.*' \
        -printf '%P\0' \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum --
) > "$SUMS_TMP"

mv -f -- "$SUMS_TMP" "$RELEASE_DIR/SHA256SUMS"
trap - EXIT

# --- self-test: the rendered manifest must validate ------------------------

if ! "$VALIDATE_MANIFEST" "$RELEASE_DIR/manifest.json"; then
    die "rendered manifest failed schema validation: $RELEASE_DIR/manifest.json"
fi

echo "build-release: wrote $RELEASE_DIR"
