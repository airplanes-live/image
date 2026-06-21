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
#   <output-dir>/systemd/airplanes-diagnostics.service  unit
#   <output-dir>/systemd/airplanes-diagnostics.timer    unit
#   <output-dir>/systemd/airplanes-config-sync.service  unit
#   <output-dir>/systemd/airplanes-config-sync.timer    unit
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
#
# Glob feed/scripts/airplanes-*.sh, mirroring the unit glob below, so a wrapper
# added in feed lands on the image automatically. The previous hand-listed
# allowlist (airplanes-feed/mlat/diagnostics.sh) silently dropped
# airplanes-stats.sh when feed added it — the overlay shipped airplanes-stats.timer
# (globbed) pointing at a script that wasn't staged. apl-feed.sh is NOT matched
# (apl-* prefix) and is staged to bin/ below; the runtime libs under
# scripts/lib/ stay an explicit curated subset (install/update-only libs are
# deliberately excluded — see below).
install -d -m 0755 "$OUTPUT_DIR/share/airplanes"
shopt -s nullglob
feed_wrappers=("$FEED_SRC"/scripts/airplanes-*.sh)
shopt -u nullglob
if [[ ${#feed_wrappers[@]} -eq 0 ]]; then
    die "no airplanes-*.sh daemon wrappers found in $FEED_SRC/scripts/"
fi
for wrapper in "${feed_wrappers[@]}"; do
    install -m 0755 "$wrapper" "$OUTPUT_DIR/share/airplanes/$(basename "$wrapper")"
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
#
# Mirror every airplanes-*.{service,timer} feed ships so a unit added in feed
# lands on the image automatically; the previous hand-maintained allowlist
# silently dropped airplanes-diagnostics.{service,timer} and
# airplanes-config-sync.{service,timer} when they were added in feed. The
# enable + symlink coverage for these units lives in
# runtime-overlay/manifest-inputs/{systemd.json,managed_paths.json} and is
# pinned by test_stage_feed_unit_symmetry.bats.
install -d -m 0755 "$OUTPUT_DIR/systemd"
shopt -s nullglob
feed_units=("$FEED_SRC"/scripts/airplanes-*.service "$FEED_SRC"/scripts/airplanes-*.timer)
shopt -u nullglob
if [[ ${#feed_units[@]} -eq 0 ]]; then
    die "no airplanes-*.{service,timer} units found in $FEED_SRC/scripts/"
fi
# Sort under LC_ALL=C so the staged-output directory listing is byte-stable
# across hosts whose locale would otherwise reorder the glob expansion.
mapfile -t feed_units < <(printf '%s\n' "${feed_units[@]}" | LC_ALL=C sort)
for src in "${feed_units[@]}"; do
    install -m 0644 "$src" "$OUTPUT_DIR/systemd/$(basename "$src")"
done

# Gate airplanes-mlat.service on the prebuilt venv this overlay ships. The
# wrapper execs /usr/local/share/airplanes/venv/bin/mlat-client; without the
# venv the unit would restart-loop on a missing interpreter. ConditionPathExists
# makes systemd skip the unit cleanly (inactive, condition-failed) on a
# decoder-only release rather than start-fail it. We inject the condition here
# (overlay side, where the venv is owned) rather than in the feed repo, whose
# unit is also consumed by the standalone installer that builds the venv at the
# same path. Idempotent: only add it if not already present.
mlat_unit="$OUTPUT_DIR/systemd/airplanes-mlat.service"
if [[ -f "$mlat_unit" ]] && ! grep -q '^ConditionPathExists=' "$mlat_unit"; then
    # Insert the condition into the [Unit] section, after the Description line.
    tmp_unit="$(mktemp)"
    awk '
        /^\[Unit\]/ { print; in_unit = 1; next }
        in_unit && /^Description=/ {
            print
            print "ConditionPathExists=/usr/local/share/airplanes/venv/bin/mlat-client"
            next
        }
        /^\[/ && !/^\[Unit\]/ { in_unit = 0 }
        { print }
    ' "$mlat_unit" > "$tmp_unit"
    install -m 0644 "$tmp_unit" "$mlat_unit"
    rm -f -- "$tmp_unit"
fi

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
# MLAT off, geo unconfigured (lat/lon=0 Atlantic placeholders, altitude and
# MLAT name left empty so they show as unset in the webconfig and the mlat
# daemon falls back to its per-device Anonymous-<short-id> name). A shell
# migration seeds /etc/airplanes/feed.env from this default on first install
# when absent (the overlay never overwrites an operator-configured feed.env).
feed_env_root="$SCRATCH_DIR/feed-env-root"
install -d -m 0755 "$feed_env_root"
(
    cd "$FEED_SRC"
    AIRPLANES_BUILD_MODE=1 \
    AIRPLANES_ROOT="$feed_env_root" \
    AIRPLANES_SKIP_ROOT_CHECK=1 \
    AIRPLANES_MLAT_USER="" \
    AIRPLANES_MLAT_ENABLED=false \
    AIRPLANES_LATITUDE=0 \
    AIRPLANES_LONGITUDE=0 \
    AIRPLANES_ALTITUDE="" \
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
# 3. Build the mlat-client Python venv at the on-device target path
# ---------------------------------------------------------------------------
#
# A Python venv embeds the absolute path it was created at into every
# console-script shebang (and into pyvenv.cfg). The airplanes-mlat wrapper
# execs /usr/local/share/airplanes/venv/bin/mlat-client, so the venv MUST be
# built at that exact path inside the container — not at a relative or
# container-scoped path — or the on-device shebangs would point at a directory
# that does not exist. We build there, verify the shebangs, then copy the tree
# verbatim into the overlay staging dir (cp -a does not rewrite shebangs).

# The venv MUST live at the path the airplanes-mlat wrapper execs. Overridable
# only for tests (which can't write under /usr/local without root); production
# always builds at the real on-device path so shebangs resolve.
VENV_TARGET="${AIRPLANES_VENV_TARGET:-/usr/local/share/airplanes/venv}"
# Test seam: a local source dir short-circuits the network clone. Production
# always clones the pinned mlat-client ref.
MLAT_SRC="${AIRPLANES_MLAT_SRC_DIR:-$SCRATCH_DIR/mlat-src}"
if [[ -n "${AIRPLANES_MLAT_SRC_DIR:-}" ]]; then
    echo "stage-feed: using local mlat-client source at $MLAT_SRC"
    MLAT_SHA="$(git -C "$MLAT_SRC" rev-parse HEAD 2>/dev/null || printf '%s' "${MLAT_REF}")"
else
    echo "stage-feed: cloning mlat-client from $MLAT_REPO @ $MLAT_REF"
    fetch_repo "$MLAT_SRC" "$MLAT_REPO" "$MLAT_REF"
    MLAT_SHA="$(git -C "$MLAT_SRC" rev-parse HEAD)"
fi

PYTHON_BIN="${AIRPLANES_PYTHON_BIN:-/usr/bin/python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    die "python interpreter not found: $PYTHON_BIN (install python3 + python3-venv)"
fi

# Record the interpreter's CPython ABI tag (e.g. cp313) so the on-device
# preflight can refuse a venv built against a Python the running base OS no
# longer ships. The compiled mlat-client C extension is ABI-locked to it.
PYTHON_ABI="$("$PYTHON_BIN" - <<'PY'
import sys
print("cp%d%d" % (sys.version_info[0], sys.version_info[1]))
PY
)"
if [[ -z "$PYTHON_ABI" ]]; then
    die "could not determine python ABI tag from $PYTHON_BIN"
fi

# Build at the literal on-device path. The container is ephemeral, so writing
# under /usr/local is safe and keeps shebangs correct without post-hoc
# rewriting. Wipe any stale tree first for idempotent local re-runs.
rm -rf -- "$VENV_TARGET"
install -d -m 0755 "$(dirname "$VENV_TARGET")"
echo "stage-feed: building mlat-client venv at $VENV_TARGET ($PYTHON_ABI)"
"$PYTHON_BIN" -m venv "$VENV_TARGET"
# shellcheck disable=SC1091
source "$VENV_TARGET/bin/activate"
# mlat-client's setup.py imports asyncore (removed in 3.12+); pyasyncore
# backfills it. setuptools/wheel are needed for the source build.
python3 -m pip install --no-input --disable-pip-version-check wheel setuptools
python3 -c "import asyncore" 2>/dev/null || python3 -m pip install --no-input pyasyncore
( cd "$MLAT_SRC" && python3 -m pip install --no-input . )
deactivate

if [[ ! -x "$VENV_TARGET/bin/mlat-client" ]]; then
    die "venv build produced no mlat-client at $VENV_TARGET/bin/mlat-client"
fi

# Shebang invariant: every console script in the venv must point its
# interpreter at the venv's own python under the on-device path. A shebang
# resolving anywhere else means the venv was built at the wrong path and would
# fail to launch on device.
shebang_bad=""
for script in "$VENV_TARGET"/bin/*; do
    [[ -f "$script" ]] || continue
    # Only text scripts carry a #! line; skip the python symlinks/binaries.
    IFS= read -r firstline < "$script" || true
    case "$firstline" in
        '#!'*)
            if [[ "$firstline" != "#!$VENV_TARGET/"* ]]; then
                shebang_bad+="$(basename "$script"): $firstline"$'\n'
            fi
            ;;
    esac
done
if [[ -n "$shebang_bad" ]]; then
    {
        echo "stage-feed: venv shebangs do not resolve under $VENV_TARGET:"
        printf '%s' "$shebang_bad"
    } >&2
    exit 1
fi

# Copy the venv into the overlay tree verbatim. cp -a preserves the absolute
# shebangs and the exec bits; the on-device path equals the build path so no
# rewriting is needed. Wipe any prior copy first so an idempotent re-run does
# not nest the tree (cp -a SRC DEST/ copies INTO DEST when DEST exists).
install -d -m 0755 "$OUTPUT_DIR/share/airplanes"
rm -rf -- "$OUTPUT_DIR/share/airplanes/venv"
cp -a "$VENV_TARGET" "$OUTPUT_DIR/share/airplanes/venv"

# Content hash over the staged venv tree (sorted file list + contents) so the
# manifest can pin exactly what shipped and a smoke test can confirm the
# on-device tree matches after extraction.
VENV_HASH="$(
    cd "$OUTPUT_DIR/share/airplanes/venv" \
        && find . -type f -print0 | LC_ALL=C sort -z \
        | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
)"

printf '%s' "$MLAT_SHA" > "$OUTPUT_DIR/components.mlat_client.sha"
printf '%s' "${MLAT_REF}" > "$OUTPUT_DIR/components.mlat_client.version"
printf '%s' "$PYTHON_ABI" > "$OUTPUT_DIR/mlat_python_abi"
printf '%s' "$VENV_HASH" > "$OUTPUT_DIR/mlat_venv_sha256"

echo "stage-feed: staged mlat-client venv (mlat_client=$MLAT_SHA abi=$PYTHON_ABI hash=${VENV_HASH:0:12})"

echo "stage-feed: staged feed artifacts (feed_readsb=$READSB_SHA feed_scripts=$FEED_SHA mlat_client=$MLAT_SHA)"
