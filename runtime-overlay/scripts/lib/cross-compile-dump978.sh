#!/usr/bin/env bash
# cross-compile-dump978.sh — clone flightaware's dump978, build the
# `dump978-fa` target, and stage the resulting binary into a release-tree
# shaped staging dir. We only build dump978-fa (the 978 MHz demodulator
# wrapper readsb's airplanes-978 unit consumes); skyaware978 is FA's
# standalone dashboard and is not shipped.
#
# Args:
#   --repo <git-url>
#   --ref <sha-or-branch>
#   --arch arm64
#   --output-dir <staging-dir>
#
# On success:
#   <output-dir>/bin/dump978-fa                   (chmod 0755)
#   <output-dir>/components.dump978_fa.sha        (full 40-hex)

set -euo pipefail

_self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

usage() {
    cat >&2 <<'USAGE'
usage: cross-compile-dump978.sh \
    --repo <git-url> \
    --ref <sha-or-branch> \
    --arch arm64 \
    --output-dir <staging-dir>
USAGE
}

die() {
    echo "cross-compile-dump978: $*" >&2
    exit 1
}

REPO=""
REF=""
ARCH=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)        REPO="${2-}";        shift 2 ;;
        --ref)         REF="${2-}";         shift 2 ;;
        --arch)        ARCH="${2-}";        shift 2 ;;
        --output-dir)  OUTPUT_DIR="${2-}";  shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage; echo "cross-compile-dump978: unknown argument: $1" >&2; exit 2 ;;
    esac
done

for required in REPO REF ARCH OUTPUT_DIR; do
    if [[ -z "${!required}" ]]; then
        flag="${required,,}"
        flag="${flag//_/-}"
        usage
        echo "cross-compile-dump978: missing required --$flag" >&2
        exit 2
    fi
done

case "$ARCH" in
    arm64) ;;
    armhf) die "--arch armhf is rejected; runtime overlay is arm64-only at v1" ;;
    *)     die "--arch must be arm64 (got: $ARCH)" ;;
esac

is_full_sha() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

host_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

fetch_repo() {
    local dir="$1" repo="$2" ref="$3"
    rm -rf -- "$dir"
    install -d -m 0755 "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$repo"
    if is_full_sha "$ref"; then
        if ! git -C "$dir" fetch --depth 1 origin "$ref" 2>/dev/null; then
            git -C "$dir" fetch origin
        fi
    else
        git -C "$dir" fetch --depth 1 origin "$ref"
    fi
    git -C "$dir" checkout -q FETCH_HEAD
}

SCRATCH_DIR="$(mktemp -d -t cross-compile-dump978.XXXXXX)"
# shellcheck disable=SC2064
trap 'rm -rf -- "$SCRATCH_DIR"' EXIT

BUILD_DIR="$SCRATCH_DIR/src"
fetch_repo "$BUILD_DIR" "$REPO" "$REF"

BUILT_SHA="$(git -C "$BUILD_DIR" rev-parse HEAD)"

if [[ "$host_arch" != "arm64" ]]; then
    die "host arch is '$host_arch' but --arch is arm64; cross-compile is not configured here — run on an arm64 host (CI uses ubuntu-24.04-arm)"
fi

# Reproducible-build flags (same shape as cross-compile-readsb.sh):
#   SOURCE_DATE_EPOCH commits the binary's embedded timestamps to the
#   commit time; -ffile-prefix-map / -fdebug-prefix-map rewrite the
#   scratch BUILD_DIR path that would otherwise appear in DWARF debug
#   info. dump978's Makefile uses CFLAGS += / CXXFLAGS +=, so passing
#   them via env preserves the upstream -Wall -Werror -O2 etc.
SOURCE_DATE_EPOCH="$(git -C "$BUILD_DIR" log -1 --format=%ct)"
export SOURCE_DATE_EPOCH
export CFLAGS="-ffile-prefix-map=$BUILD_DIR=. -fdebug-prefix-map=$BUILD_DIR=."
export CXXFLAGS="$CFLAGS"

# `make dump978-fa` only — skyaware978 not shipped.
(
    cd "$BUILD_DIR"
    make -j"$(nproc)" dump978-fa
)

install -d -m 0755 "$OUTPUT_DIR/bin"

if [[ ! -f "$BUILD_DIR/dump978-fa" ]]; then
    die "build produced no dump978-fa binary at $BUILD_DIR/dump978-fa"
fi
install -m 0755 "$BUILD_DIR/dump978-fa" "$OUTPUT_DIR/bin/dump978-fa"

# Unresolved-libs check — boost/soapy/usb are the typical culprits when
# build-deps drift.
if ldd "$OUTPUT_DIR/bin/dump978-fa" 2>&1 | grep -q 'not found'; then
    {
        echo "cross-compile-dump978: dump978-fa has unresolved shared libraries:"
        ldd "$OUTPUT_DIR/bin/dump978-fa" | grep 'not found' || true
    } >&2
    exit 1
fi

printf '%s\n' "$BUILT_SHA" > "$OUTPUT_DIR/components.dump978_fa.sha"

echo "cross-compile-dump978: staged $OUTPUT_DIR/bin/dump978-fa at $BUILT_SHA"
