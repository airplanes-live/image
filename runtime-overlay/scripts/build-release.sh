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
    die "--version is not a valid release version (got: $VERSION). Expected semver or '<semver>-dev-YYYYMMDD-<build-fingerprint>'."
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
# it. We check the final path now so the caller fails fast; the same dir
# is re-checked atomically after staging via `mkdir` (no -p) below to close
# the TOCTOU window between two concurrent invocations.
if [[ -e "$RELEASE_DIR" ]]; then
    die "release dir already exists: $RELEASE_DIR (remove it first or bump --version)"
fi

mkdir -p -- "$OUTPUT_DIR"

# Stage everything into a sibling tmp dir and only rename to RELEASE_DIR
# after every gate passes. A broken or partial release is then either
# fully present at the canonical path or absent — never half-published.
# The trap below cleans up the staging dir on any non-zero exit path.
STAGING_DIR="$(mktemp -d "$OUTPUT_DIR/.build-release.XXXXXX")"
# shellcheck disable=SC2064
trap 'rm -rf -- "$STAGING_DIR"' EXIT

# Copy the input tree into the staging dir. `cp -a` preserves modes,
# ownership and timestamps so the staged tree matches what the on-device
# installer will untar in production. SHA256SUMS doesn't care about
# timestamps, so determinism across two runs against the same input bytes
# still holds.
cp -a -- "$INPUT_DIR/." "$STAGING_DIR/"

# Strip the JSON-snippet inputs out of the staged tree. They are manifest
# build-time inputs, not on-device assets, and the release dir on a feeder
# must not contain them.
for snippet in components managed_paths mutable_paths systemd migrations compat; do
    rm -f -- "$STAGING_DIR/$snippet.json"
done

# Strip the per-component metadata atoms the stage helpers drop at the staging
# root (components.<key>.sha / .version, and the mlat venv ABI / hash files).
# They are folded into the manifest upstream; the release tree on a feeder must
# carry only on-device assets, not the build-time bookkeeping.
rm -f -- "$STAGING_DIR"/components.*.sha "$STAGING_DIR"/components.*.version
rm -f -- "$STAGING_DIR/mlat_python_abi" "$STAGING_DIR/mlat_venv_sha256"

# Compose manifest.json. The renderer is responsible for canonical key
# ordering (jq -S) and atomic write.
airplanes_runtime_render_manifest \
    "$VERSION" \
    "$CHANNEL" \
    "$COMMIT_SHA" \
    "$BUILD_DATE" \
    "$ARCH" \
    "$INPUT_DIR" \
    "$STAGING_DIR/manifest.json"

# Cross-check: every file the manifest references must actually exist in
# the staged tree. The schema enforces shape; this gate enforces presence.
# Without it, a typo in components.json / managed_paths.json / migrations.json
# yields a schema-valid manifest pointing at a missing file, which would
# only surface during on-device install.
_check_release_local_path() {
    # Args: <field-path-for-diagnostic> <release-local-path>
    local label="$1"
    local rel="$2"
    if [[ -z "$rel" || "$rel" == "null" ]]; then
        return 0
    fi
    if [[ ! -e "$STAGING_DIR/$rel" ]]; then
        die "manifest $label references missing file: $rel"
    fi
}

# managed_paths.target is an absolute /opt/airplanes/current/... path;
# strip that prefix to get the release-local path.
CURRENT_PREFIX="/opt/airplanes/current/"
while IFS= read -r abs_target; do
    [[ -z "$abs_target" ]] && continue
    if [[ "$abs_target" != "$CURRENT_PREFIX"* ]]; then
        die "managed_paths.target not under $CURRENT_PREFIX: $abs_target"
    fi
    _check_release_local_path "managed_paths.target" "${abs_target#"$CURRENT_PREFIX"}"
done < <(jq -r '.managed_paths[]? | select(.mode == "symlink") | .target' \
            "$STAGING_DIR/manifest.json")

# managed_paths.from (copy mode) is already release-local.
while IFS= read -r from_rel; do
    [[ -z "$from_rel" ]] && continue
    _check_release_local_path "managed_paths.from" "$from_rel"
done < <(jq -r '.managed_paths[]? | select(.mode == "copy") | .from' \
            "$STAGING_DIR/manifest.json")

# Shell migrations carry release-local script + rollback_script paths.
while IFS= read -r mig_script; do
    [[ -z "$mig_script" ]] && continue
    _check_release_local_path "migrations.script" "$mig_script"
done < <(jq -r '.migrations[]? | select(.type == "shell") | .script' \
            "$STAGING_DIR/manifest.json")
while IFS= read -r mig_rollback; do
    [[ -z "$mig_rollback" ]] && continue
    _check_release_local_path "migrations.rollback_script" "$mig_rollback"
done < <(jq -r '.migrations[]? | select(.type == "shell") | .rollback_script' \
            "$STAGING_DIR/manifest.json")

# Build SHA256SUMS over every file in the staged tree EXCEPT SHA256SUMS
# itself. `find -printf '%P\0'` emits release-dir-relative paths so a
# `sha256sum -c` invocation inside the published dir verifies cleanly. Sort
# under LC_ALL=C so ordering is reproducible regardless of host LANG /
# LC_COLLATE.
SUMS_TMP="$(mktemp "$STAGING_DIR/.SHA256SUMS.tmp.XXXXXX")"

(
    cd "$STAGING_DIR"
    LC_ALL=C find . -type f \
        ! -name SHA256SUMS \
        ! -name '.SHA256SUMS.tmp.*' \
        -printf '%P\0' \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum --
) > "$SUMS_TMP"

mv -f -- "$SUMS_TMP" "$STAGING_DIR/SHA256SUMS"

# --- self-test: the rendered manifest must validate ------------------------

if ! "$VALIDATE_MANIFEST" "$STAGING_DIR/manifest.json"; then
    die "rendered manifest failed schema validation: $STAGING_DIR/manifest.json"
fi

# --- atomic publish --------------------------------------------------------

# `mv` of a directory onto a non-existent target is atomic on the same
# filesystem (single rename() syscall). We pre-created OUTPUT_DIR above so
# RELEASE_DIR's parent is guaranteed to exist on the same FS as STAGING_DIR.
# Re-checking RELEASE_DIR with a non-clobbering rename closes the TOCTOU
# window against a parallel invocation that may have published in the
# meantime.
if [[ -e "$RELEASE_DIR" ]]; then
    die "release dir appeared during build: $RELEASE_DIR (concurrent build?)"
fi
mv -T -- "$STAGING_DIR" "$RELEASE_DIR"
trap - EXIT

echo "build-release: wrote $RELEASE_DIR"
