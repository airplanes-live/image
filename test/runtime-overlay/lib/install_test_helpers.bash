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
        "$r/run/dump978-fa" \
        "$r/var/lib/airplanes-runtime-upgrade" \
        "$r/run/airplanes"
    printf '%s' "$r"
}

# Write a state file under <target_root> with the supplied state name and
# optional `key=value` extras (prev_release=..., new_release=...,
# started_at=..., failure_reason=...). Used by the recovery tests to
# synthesise each row of the recovery matrix.
mk_state_file() {
    local target_root="$1" state="$2"; shift 2
    local dir="$target_root/var/lib/airplanes-runtime-upgrade"
    install -d -m 755 "$dir"
    {
        printf 'state=%s\n' "$state"
        local kv
        for kv in "$@"; do
            printf '%s\n' "$kv"
        done
    } > "$dir/upgrade-state"
    chmod 0644 "$dir/upgrade-state"
}

# Read the `state=` value from <target_root>'s upgrade-state file.
read_state() {
    local target_root="$1"
    local f="$target_root/var/lib/airplanes-runtime-upgrade/upgrade-state"
    [[ -r "$f" ]] || { printf ''; return 0; }
    awk -F= '/^state=/ { sub(/^state=/, ""); print; exit }' "$f"
}

# Stage a synthetic release directory tree under <target_root> at
# /opt/airplanes-runtime/releases/v<version>/. Writes a minimal manifest
# the recovery + rollback paths can read. Echoes the absolute release dir.
mk_target_release() {
    local target_root="$1" version="$2"
    local d="$target_root/opt/airplanes-runtime/releases/v$version"
    install -d -m 755 \
        "$d/bin" \
        "$d/lib" \
        "$d/share/airplanes" \
        "$d/systemd" \
        "$d/lib/airplanes" \
        "$d/migrations" \
        "$d/etc"
    : > "$d/bin/readsb"
    chmod 755 "$d/bin/readsb"
    cat > "$d/manifest.json" <<JSON
{
    "version": "$version",
    "channel": "stable",
    "commit_sha": "0000000000000000000000000000000000000000",
    "build_date": "2026-05-20T00:00:00Z",
    "arches": ["arm64"],
    "components": { "readsb_wiedehopf": "0000000" },
    "managed_paths": [],
    "mutable_paths": [],
    "systemd": { "enable": [], "daemon_reload": true },
    "migrations": []
}
JSON
    printf '%s' "$d"
}

# Stage a systemctl shim that logs every invocation into <log> and exits
# 0. Returns the directory the shim was placed in (caller prepends to
# PATH).
mk_systemctl_shim() {
    local shim_dir="$1" log="$2"
    install -d -m 755 "$shim_dir"
    : > "$log"
    cat > "$shim_dir/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$log"
exit 0
EOF
    chmod 755 "$shim_dir/systemctl"
    printf '%s' "$shim_dir"
}
