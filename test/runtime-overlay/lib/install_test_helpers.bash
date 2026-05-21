# shellcheck shell=bash
#
# install_test_helpers.bash — shared bash helpers for the runtime-overlay
# install bats tests. Sourced from each test's setup() block via
# `load lib/install_test_helpers`.
#
# Provides:
#   - REPO_ROOT / OVERLAY_DIR / LIB_PATH constants
#   - source_install_lib  — sources install-common.sh with offline-safe defaults
#   - mk_release_dir <work>  — creates a minimal staged release dir layout
#   - mk_target_root <work>  — creates a tmpdir target root with the FHS skeleton
#                              the install path writes into

if [[ -z "${BATS_TEST_DIRNAME:-}" ]]; then
    echo "install_test_helpers: must be sourced from a bats test" >&2
    exit 2
fi

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
OVERLAY_DIR="$REPO_ROOT/runtime-overlay"
LIB_PATH="$OVERLAY_DIR/scripts/lib/install-common.sh"

source_install_lib() {
    # Pin offline-safe defaults so a misconfigured test doesn't surprise-call
    # github.com during ls-remote.
    : "${AIRPLANES_RUNTIME_REPO:=file:///dev/null}"
    : "${AIRPLANES_RUNTIME_DOWNLOAD_BASE:=file:///dev/null}"
    : "${AIRPLANES_RUNTIME_MINISIGN_PUBKEY:=/dev/null}"
    export AIRPLANES_RUNTIME_REPO AIRPLANES_RUNTIME_DOWNLOAD_BASE AIRPLANES_RUNTIME_MINISIGN_PUBKEY
    # shellcheck disable=SC1090
    . "$LIB_PATH"
}

# Pre-shape a release directory under <work>/releases/v<ver>/. Echoes the path.
mk_release_dir() {
    local work="$1" version="${2:-1.0.0}"
    local d="$work/releases/v$version"
    install -d -m 755 \
        "$d/bin" \
        "$d/share/airplanes" \
        "$d/systemd" \
        "$d/lib/airplanes" \
        "$d/migrations" \
        "$d/etc"
    : > "$d/bin/readsb"
    chmod 755 "$d/bin/readsb"
    : > "$d/share/airplanes/readsb.sh"
    chmod 755 "$d/share/airplanes/readsb.sh"
    printf '%s' "$d"
}

# Create a target root tmpdir laid out like a feeder rootfs. Echoes the path.
mk_target_root() {
    local work="$1"
    local r="$work/root"
    install -d -m 755 \
        "$r/opt/airplanes-runtime/releases" \
        "$r/opt/airplanes-runtime" \
        "$r/etc/airplanes" \
        "$r/etc/systemd/system" \
        "$r/usr/bin" \
        "$r/run/readsb" \
        "$r/run/airplanes-978" \
        "$r/run/dump978-fa"
    printf '%s' "$r"
}
