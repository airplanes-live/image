#!/usr/bin/env bash
# cross-compile-readsb.sh — clone the wiedehopf readsb fork, compile, and
# stage the produced binaries under a release-tree-shaped output directory.
#
# This helper re-implements what `stage-airplanes/02-install-decoder/`
# (specifically `01-run-chroot.sh:22`) does for a pi-gen chroot, except the
# output goes into a staging tree the runtime-overlay release tarball will
# package — not into a chroot's /usr/bin. The build flags (AIRCRAFT_HASH_BITS,
# RTLSDR=yes) and the `make -j$(nproc)` shape match the legacy stage so the
# resulting binary is byte-identical to what stage 02 produces for an arm64
# build (modulo timestamps).
#
# Args:
#   --repo <git-url>         upstream git URL (e.g. wiedehopf readsb)
#   --ref <sha-or-branch>    full 40-hex SHA or branch name
#   --arch arm64             target architecture; v1 is arm64-only
#   --output-dir <staging>   per-arch staging dir to populate
#
# On success:
#   <output-dir>/bin/readsb            (chmod 0755)
#   <output-dir>/bin/viewadsb          (if produced by the build)
#   <output-dir>/components.readsb_wiedehopf.sha   (full 40-hex)
#
# Exit codes:
#   0  ok
#   1  build/composition failure
#   2  bad argument

set -euo pipefail

_self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

usage() {
    cat >&2 <<'USAGE'
usage: cross-compile-readsb.sh \
    --repo <git-url> \
    --ref <sha-or-branch> \
    --arch arm64 \
    --output-dir <staging-dir>
USAGE
}

die() {
    echo "cross-compile-readsb: $*" >&2
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
        *)             usage; echo "cross-compile-readsb: unknown argument: $1" >&2; exit 2 ;;
    esac
done

for required in REPO REF ARCH OUTPUT_DIR; do
    if [[ -z "${!required}" ]]; then
        flag="${required,,}"
        flag="${flag//_/-}"
        usage
        echo "cross-compile-readsb: missing required --$flag" >&2
        exit 2
    fi
done

case "$ARCH" in
    arm64) ;;
    armhf) die "--arch armhf is rejected; runtime overlay is arm64-only at v1" ;;
    *)     die "--arch must be arm64 (got: $ARCH)" ;;
esac

# `ref` is either a full 40-hex SHA (do a full clone + checkout — `git fetch`
# at a SHA depends on server config) or a branch name (cheap --depth 1).
# The legacy stage 02 always uses --depth 1 because config-stable still pins
# via branch ref + companion SHA-record file. Match that shape but be tolerant
# of a 40-hex SHA in case A-5 wires us up with concrete SHAs.
is_full_sha() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

host_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

# Mirror the legacy stage's idempotent fetch shape: init + remote + fetch +
# checkout FETCH_HEAD, so the working tree is always a clean checkout at the
# requested ref regardless of whether the ref is a branch tip or a frozen SHA.
fetch_repo() {
    local dir="$1" repo="$2" ref="$3"
    rm -rf -- "$dir"
    install -d -m 0755 "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$repo"
    if is_full_sha "$ref"; then
        # `--depth 1` against a SHA needs uploadpack.allowReachableSHA1InWant
        # on the remote, which GitHub honours. Fall back to full clone if not.
        if ! git -C "$dir" fetch --depth 1 origin "$ref" 2>/dev/null; then
            git -C "$dir" fetch origin
        fi
    else
        git -C "$dir" fetch --depth 1 origin "$ref"
    fi
    git -C "$dir" checkout -q FETCH_HEAD
}

# Scratch under a parent the caller can reason about. We deliberately do NOT
# put scratch inside <output-dir> — the output tree is what the release
# tarball will ship, and a leaked .git or build artefacts would bloat it.
SCRATCH_DIR="$(mktemp -d -t cross-compile-readsb.XXXXXX)"
# shellcheck disable=SC2064
trap 'rm -rf -- "$SCRATCH_DIR"' EXIT

BUILD_DIR="$SCRATCH_DIR/src"
fetch_repo "$BUILD_DIR" "$REPO" "$REF"

# Capture the post-checkout SHA. For a branch ref this resolves to the tip
# we just fetched; for a SHA ref it equals the SHA. Either way it is the
# pin to record in components.readsb_wiedehopf.sha.
BUILT_SHA="$(git -C "$BUILD_DIR" rev-parse HEAD)"

# Build. Matches `stage-airplanes/02-install-decoder/01-run-chroot.sh:22`
# verbatim modulo armhf branch (rejected upstream of here for v1).
if [[ "$host_arch" != "arm64" ]]; then
    die "host arch is '$host_arch' but --arch is arm64; cross-compile is not configured here — run on an arm64 host (CI uses ubuntu-24.04-arm)"
fi

# Reproducible-build flags:
#   SOURCE_DATE_EPOCH      — fixes any __DATE__/__TIME__ baked into the
#                            binary to the commit timestamp.
#   -ffile-prefix-map      — rewrites the scratch BUILD_DIR path that
#                            would otherwise appear in DWARF debug info
#                            (__FILE__ strings, .debug_str entries).
#   -fdebug-prefix-map     — same intent for older GCC versions that
#                            do not honour -ffile-prefix-map for debug
#                            info specifically. Both are emitted; the
#                            superset is the cheap, deterministic choice.
# readsb's Makefile honours OPTIMIZE for appended C/CFLAGS — pass the
# prefix-map flags via that channel rather than overriding CFLAGS
# wholesale (which would lose the Makefile's own -O3 and friends).
SOURCE_DATE_EPOCH="$(git -C "$BUILD_DIR" log -1 --format=%ct)"
export SOURCE_DATE_EPOCH
REPRO_FLAGS="-ffile-prefix-map=$BUILD_DIR=. -fdebug-prefix-map=$BUILD_DIR=."

(
    cd "$BUILD_DIR"
    make -j"$(nproc)" AIRCRAFT_HASH_BITS=12 RTLSDR=yes \
        OPTIMIZE="$REPRO_FLAGS"
)

# Stage. The release-tree shape under <output-dir>/bin/ matches what
# build-release.sh expects: bin/readsb, bin/dump978-fa (the latter from
# cross-compile-dump978.sh). NO airplanes-978 symlink — install.sh creates
# it on-device per the resolved design.
install -d -m 0755 "$OUTPUT_DIR/bin"

if [[ ! -f "$BUILD_DIR/readsb" ]]; then
    die "build produced no readsb binary at $BUILD_DIR/readsb"
fi
install -m 0755 "$BUILD_DIR/readsb" "$OUTPUT_DIR/bin/readsb"

# viewadsb is built alongside readsb by the same Makefile and is installed
# by stage 02. Stage it iff present.
if [[ -f "$BUILD_DIR/viewadsb" ]]; then
    install -m 0755 "$BUILD_DIR/viewadsb" "$OUTPUT_DIR/bin/viewadsb"
fi

# Belt-and-braces unresolved-library check. The release-time verify gate
# (A-5) does this too, but doing it at staging time catches a missing
# build-deps install (libusb / librtlsdr / libncurses) before the bigger
# composition gates run.
if ldd "$OUTPUT_DIR/bin/readsb" 2>&1 | grep -q 'not found'; then
    {
        echo "cross-compile-readsb: readsb has unresolved shared libraries:"
        ldd "$OUTPUT_DIR/bin/readsb" | grep 'not found' || true
    } >&2
    exit 1
fi

# Record the pin. The aggregator helper concatenates these per-component SHA
# files into a single components.json that build-release.sh consumes.
printf '%s\n' "$BUILT_SHA" > "$OUTPUT_DIR/components.readsb_wiedehopf.sha"

echo "cross-compile-readsb: staged $OUTPUT_DIR/bin/readsb at $BUILT_SHA"
