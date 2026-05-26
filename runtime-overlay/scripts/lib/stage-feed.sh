#!/usr/bin/env bash
# stage-feed.sh — clone airplanes-live/feed at a pinned ref, cross-compile
# the feeder readsb binary from airplanes-live/readsb, build the mlat-client
# Python venv, and stage all feed artifacts into the runtime-overlay build
# tree. Unlike webconfig (a downloaded GitHub release), feed is overlay-built.
#
# The overlay build runs inside a Debian trixie arm64 container
# (build-image.yml's build-runtime job), so native compilation works.
#
# Args:
#   --feed-repo <git-url>          feed scripts repo
#   --feed-ref <sha-or-branch>     feed scripts pin
#   --readsb-repo <git-url>        feeder readsb fork (outbound feed binary)
#   --readsb-ref <sha-or-branch>   feeder readsb pin
#   --mlat-repo <git-url>          mlat-client repo
#   --mlat-ref <sha-or-branch>     mlat-client pin
#   --arch <arm64>                 target architecture
#   --output-dir <staging>         per-arch staging dir to populate
#
# On success:
#   <output-dir>/bin/feed-airplanes                     feeder readsb binary
#   <output-dir>/share/airplanes/*.sh                   daemon wrappers
#   <output-dir>/share/airplanes/apl-feed/*.sh          subcommand scripts
#   <output-dir>/share/airplanes/lib/*.sh               runtime libs
#   <output-dir>/share/airplanes/venv/                  mlat-client venv
#   <output-dir>/bin/apl-feed                           CLI entry point
#   <output-dir>/systemd/airplanes-feed.service         unit
#   <output-dir>/systemd/airplanes-mlat.service         unit
#   <output-dir>/components.feed_readsb.sha             commit SHA
#   <output-dir>/components.feed_readsb.version         version tag
#   <output-dir>/components.feed_scripts.sha            commit SHA
#   <output-dir>/components.feed_scripts.version        version tag
#   <output-dir>/components.mlat_client.sha             commit SHA
#   <output-dir>/components.mlat_client.version         version tag

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: stage-feed.sh \
    --feed-repo <git-url> --feed-ref <sha-or-branch> \
    --readsb-repo <git-url> --readsb-ref <sha-or-branch> \
    --mlat-repo <git-url> --mlat-ref <sha-or-branch> \
    --arch <arm64> --output-dir <staging>
USAGE
}

die() {
    echo "stage-feed: $*" >&2
    exit 1
}

FEED_REPO=""
FEED_REF=""
READSB_REPO=""
READSB_REF=""
MLAT_REPO=""
MLAT_REF=""
ARCH=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --feed-repo)    FEED_REPO="${2-}";    shift 2 ;;
        --feed-ref)     FEED_REF="${2-}";     shift 2 ;;
        --readsb-repo)  READSB_REPO="${2-}";  shift 2 ;;
        --readsb-ref)   READSB_REF="${2-}";   shift 2 ;;
        --mlat-repo)    MLAT_REPO="${2-}";    shift 2 ;;
        --mlat-ref)     MLAT_REF="${2-}";     shift 2 ;;
        --arch)         ARCH="${2-}";         shift 2 ;;
        --output-dir)   OUTPUT_DIR="${2-}";   shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage; die "unknown argument: $1" ;;
    esac
done

for required in FEED_REPO FEED_REF READSB_REPO READSB_REF MLAT_REPO MLAT_REF ARCH OUTPUT_DIR; do
    if [[ -z "${!required}" ]]; then
        flag="${required,,}"
        flag="${flag//_/-}"
        usage
        die "missing required --$flag"
    fi
done

case "$ARCH" in
    arm64) ;;
    *) die "--arch must be arm64 (got: $ARCH)" ;;
esac

is_full_sha() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

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

host_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

SCRATCH_DIR="$(mktemp -d -t stage-feed.XXXXXX)"
trap 'rm -rf -- "$SCRATCH_DIR"' EXIT

# ---------------------------------------------------------------------------
# 1. Cross-compile feeder readsb from airplanes-live/readsb
# ---------------------------------------------------------------------------

READSB_BUILD="$SCRATCH_DIR/readsb-src"
echo "stage-feed: cloning feeder readsb from $READSB_REPO @ $READSB_REF"
fetch_repo "$READSB_BUILD" "$READSB_REPO" "$READSB_REF"
READSB_SHA="$(git -C "$READSB_BUILD" rev-parse HEAD)"

if [[ "$host_arch" != "arm64" ]]; then
    die "host arch is '$host_arch' but --arch is arm64; run on an arm64 host"
fi

SOURCE_DATE_EPOCH="$(git -C "$READSB_BUILD" log -1 --format=%ct)"
export SOURCE_DATE_EPOCH
REPRO_FLAGS="-ffile-prefix-map=$READSB_BUILD=. -fdebug-prefix-map=$READSB_BUILD=."

echo "stage-feed: compiling feeder readsb (AIRCRAFT_HASH_BITS=12)"
(
    cd "$READSB_BUILD"
    make -j"$(nproc)" AIRCRAFT_HASH_BITS=12 \
        OPTIMIZE="$REPRO_FLAGS"
)

if [[ ! -f "$READSB_BUILD/readsb" ]]; then
    die "build produced no readsb binary at $READSB_BUILD/readsb"
fi

install -d -m 0755 "$OUTPUT_DIR/bin"
install -m 0755 "$READSB_BUILD/readsb" "$OUTPUT_DIR/bin/feed-airplanes"

if ldd "$OUTPUT_DIR/bin/feed-airplanes" 2>&1 | grep -q 'not found'; then
    {
        echo "stage-feed: feed-airplanes has unresolved shared libraries:"
        ldd "$OUTPUT_DIR/bin/feed-airplanes" | grep 'not found' || true
    } >&2
    exit 1
fi

printf '%s' "$READSB_SHA" > "$OUTPUT_DIR/components.feed_readsb.sha"
printf '%s' "${READSB_REF}" > "$OUTPUT_DIR/components.feed_readsb.version"

# ---------------------------------------------------------------------------
# 2. Clone feed scripts and stage runtime artifacts
# ---------------------------------------------------------------------------

FEED_SRC="$SCRATCH_DIR/feed-src"
echo "stage-feed: cloning feed scripts from $FEED_REPO @ $FEED_REF"
fetch_repo "$FEED_SRC" "$FEED_REPO" "$FEED_REF"
FEED_SHA="$(git -C "$FEED_SRC" rev-parse HEAD)"

# Daemon wrappers → share/airplanes/
install -d -m 0755 "$OUTPUT_DIR/share/airplanes"
for wrapper in airplanes-feed.sh airplanes-mlat.sh airplanes-diagnostics.sh; do
    if [[ -f "$FEED_SRC/scripts/$wrapper" ]]; then
        install -m 0755 "$FEED_SRC/scripts/$wrapper" "$OUTPUT_DIR/share/airplanes/$wrapper"
    fi
done

# apl-feed CLI entry point → bin/
install -m 0755 "$FEED_SRC/scripts/apl-feed.sh" "$OUTPUT_DIR/bin/apl-feed"

# apl-feed subcommand scripts → share/airplanes/apl-feed/
install -d -m 0755 "$OUTPUT_DIR/share/airplanes/apl-feed"
for sub in "$FEED_SRC"/scripts/apl-feed/*.sh; do
    [[ -f "$sub" ]] || continue
    install -m 0644 "$sub" "$OUTPUT_DIR/share/airplanes/apl-feed/"
done

# Runtime libs → share/airplanes/lib/
install -d -m 0755 "$OUTPUT_DIR/share/airplanes/lib"
for lib in state-writer.sh state-reader.sh configure-validators.sh feed-env-keys.sh feed-env-apply.sh legacy-mlat-translation.sh; do
    if [[ -f "$FEED_SRC/scripts/lib/$lib" ]]; then
        install -m 0644 "$FEED_SRC/scripts/lib/$lib" "$OUTPUT_DIR/share/airplanes/lib/$lib"
    fi
done

# Systemd units → systemd/
install -d -m 0755 "$OUTPUT_DIR/systemd"
for unit in airplanes-feed.service airplanes-mlat.service; do
    if [[ -f "$FEED_SRC/scripts/$unit" ]]; then
        install -m 0644 "$FEED_SRC/scripts/$unit" "$OUTPUT_DIR/systemd/$unit"
    fi
done

# Stage .shellcheckrc so the verify-gates shellcheck over the release tree
# honours the feed repo's suppressions (SC2034: unused-looking associative
# array keys that are actually consumed by callers via source). Without it,
# SC2034 in feed-env-apply.sh would fail the release gate.
if [[ -f "$FEED_SRC/.shellcheckrc" ]]; then
    install -m 0644 "$FEED_SRC/.shellcheckrc" "$OUTPUT_DIR/share/airplanes/.shellcheckrc"
fi

# Generate the default fresh-image feed.env by running feed's own configure.sh
# in build mode against a throwaway root, so the template is the canonical
# feed contract (not a bespoke image-side duplicate). Fresh-image posture:
# MLAT off, geo unconfigured (lat/lon=0 Atlantic placeholders), MLAT_USER set
# to the image marker. A shell migration seeds /etc/airplanes/feed.env from
# this default on first install when absent (the overlay never overwrites an
# operator-configured feed.env).
feed_env_root="$SCRATCH_DIR/feed-env-root"
install -d -m 0755 "$feed_env_root"
(
    cd "$FEED_SRC"
    AIRPLANES_BUILD_MODE=1 \
    AIRPLANES_ROOT="$feed_env_root" \
    AIRPLANES_SKIP_ROOT_CHECK=1 \
    AIRPLANES_MLAT_USER=airplanes-live-image \
    AIRPLANES_MLAT_ENABLED=false \
    AIRPLANES_LATITUDE=0 \
    AIRPLANES_LONGITUDE=0 \
    AIRPLANES_ALTITUDE=0m \
        bash configure.sh --build-mode
)
if [[ ! -f "$feed_env_root/etc/airplanes/feed.env" ]]; then
    die "feed configure.sh --build-mode did not produce a default feed.env"
fi
install -m 0644 "$feed_env_root/etc/airplanes/feed.env" \
    "$OUTPUT_DIR/share/airplanes/feed.env.default"

printf '%s' "$FEED_SHA" > "$OUTPUT_DIR/components.feed_scripts.sha"
printf '%s' "${FEED_REF}" > "$OUTPUT_DIR/components.feed_scripts.version"

# ---------------------------------------------------------------------------
# 3. Build mlat-client venv at the target absolute path
# ---------------------------------------------------------------------------

MLAT_SRC="$SCRATCH_DIR/mlat-src"
echo "stage-feed: cloning mlat-client from $MLAT_REPO @ $MLAT_REF"
fetch_repo "$MLAT_SRC" "$MLAT_REPO" "$MLAT_REF"
MLAT_SHA="$(git -C "$MLAT_SRC" rev-parse HEAD)"

VENV_TARGET="/usr/local/share/airplanes/venv"
echo "stage-feed: building mlat-client venv at $VENV_TARGET"

rm -rf "$VENV_TARGET"
python3 -m venv "$VENV_TARGET"

(
    # shellcheck disable=SC1091
    . "$VENV_TARGET/bin/activate"
    python3 -c "import setuptools" 2>/dev/null || python3 -m pip install setuptools
    python3 -c "import asyncore" 2>/dev/null || python3 -m pip install pyasyncore
    python3 -m pip install wheel
    cd "$MLAT_SRC"
    pip install .
)

# Verify shebang resolves
if ! grep -qs '#!' "$VENV_TARGET/bin/mlat-client"; then
    die "mlat-client binary missing or has no shebang in $VENV_TARGET/bin/mlat-client"
fi

# Stage the venv into the overlay tree
install -d -m 0755 "$OUTPUT_DIR/share/airplanes"
cp -a "$VENV_TARGET" "$OUTPUT_DIR/share/airplanes/venv"

# Compute content hash for future smoke tests
VENV_HASH="$(find "$OUTPUT_DIR/share/airplanes/venv" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
printf '%s' "$VENV_HASH" > "$OUTPUT_DIR/share/airplanes/venv.sha256"

printf '%s' "$MLAT_SHA" > "$OUTPUT_DIR/components.mlat_client.sha"
printf '%s' "${MLAT_REF}" > "$OUTPUT_DIR/components.mlat_client.version"

echo "stage-feed: staged feed artifacts (feed_readsb=$READSB_SHA feed_scripts=$FEED_SHA mlat_client=$MLAT_SHA)"
