#!/usr/bin/env bats

# Tests for the image-owned boot-recovery pointer shim at
# stage-airplanes/02-install-runtime-overlay/files/usr/local/lib/
# airplanes-runtime/recover-shim.
#
# The shim uses POSIX sh + base-OS tools only (no jq, no python, no
# install-common.sh) so it survives a fully broken overlay. These tests
# verify that contract: they run the shim directly without sourcing any
# overlay library.

bats_require_minimum_version 1.5.0

load lib/install_test_helpers

SHIM_PATH="$REPO_ROOT/stage-airplanes/02-install-runtime-overlay/files/opt/airplanes/libexec/recover-shim"

setup() {
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    export AIRPLANES_RECOVER_ROOT="$TARGET_ROOT"
}

# Helper: write a state file for the shim (uses the shim's own path layout).
shim_state() {
    local state="$1"; shift
    local dir="$TARGET_ROOT/var/lib/airplanes/runtime-upgrade"
    install -d -m 755 "$dir"
    {
        printf 'state=%s\n' "$state"
        local kv
        for kv in "$@"; do
            printf '%s\n' "$kv"
        done
    } > "$dir/upgrade-state"
}

# Helper: create a valid release tree at a device-canonical path.
shim_release() {
    local version="$1"
    local d="$TARGET_ROOT/opt/airplanes/releases/v$version"
    install -d -m 755 "$d"
    printf '{"version":"%s"}\n' "$version" > "$d/manifest.json"
    printf '%s' "/opt/airplanes/releases/v$version"
}

# Helper: point current at a device-canonical release path.
shim_current() {
    local dev_path="$1"
    local link="$TARGET_ROOT/opt/airplanes/current"
    install -d -m 755 "$(dirname "$link")"
    rm -f "$link"
    ln -s "$dev_path" "$link"
}

# Helper: read the state token from the state file.
shim_read_state() {
    sed -n 's/^state=//p' "$TARGET_ROOT/var/lib/airplanes/runtime-upgrade/upgrade-state" 2>/dev/null | head -n1
}

# Helper: read the recovery-status token.
shim_read_status() {
    sed -n 's/^status=//p' "$TARGET_ROOT/var/lib/airplanes/runtime-upgrade/recovery-status" 2>/dev/null | head -n1
}

# ---------------------------------------------------------------------------
# HEALTH_PASSED is a no-op (does NOT roll back a good release)
# ---------------------------------------------------------------------------
@test "shim: HEALTH_PASSED is a no-op — does not roll back" {
    local prev new
    prev="$(shim_release 1.0.0)"
    new="$(shim_release 1.1.0)"
    shim_current "/opt/airplanes/releases/v1.1.0"
    shim_state HEALTH_PASSED \
        "prev_release=/opt/airplanes/releases/v1.0.0" \
        "new_release=/opt/airplanes/releases/v1.1.0"

    run sh "$SHIM_PATH"
    [ "$status" -eq 0 ]
    # current must NOT have changed — still points at 1.1.0.
    local cur
    cur="$(readlink "$TARGET_ROOT/opt/airplanes/current")"
    [ "$cur" = "/opt/airplanes/releases/v1.1.0" ]
    [ "$(shim_read_status)" = "ok" ]
}

# ---------------------------------------------------------------------------
# SYMLINK_FLIPPED flips back to prev
# ---------------------------------------------------------------------------
@test "shim: SYMLINK_FLIPPED flips current back to prev_release" {
    local prev new
    prev="$(shim_release 1.0.0)"
    new="$(shim_release 1.1.0)"
    shim_current "/opt/airplanes/releases/v1.1.0"
    shim_state SYMLINK_FLIPPED \
        "prev_release=/opt/airplanes/releases/v1.0.0" \
        "new_release=/opt/airplanes/releases/v1.1.0"

    run sh "$SHIM_PATH"
    [ "$status" -eq 0 ]
    local cur
    cur="$(readlink "$TARGET_ROOT/opt/airplanes/current")"
    [ "$cur" = "/opt/airplanes/releases/v1.0.0" ]
    [[ "$(shim_read_state)" == ROLLED_BACK_SHIM_ONLY_FROM_SYMLINK_FLIPPED ]]
    [ "$(shim_read_status)" = "rolled_back" ]
}

# ---------------------------------------------------------------------------
# Missing prev_release falls back to last-good-release
# ---------------------------------------------------------------------------
@test "shim: missing prev_release falls back to last-good-release" {
    shim_release 0.9.0
    shim_current "/opt/airplanes/releases/v1.1.0"
    shim_state SYMLINK_FLIPPED \
        "prev_release=/opt/airplanes/releases/v_GONE" \
        "new_release=/opt/airplanes/releases/v1.1.0"
    # Write last-good pointing at 0.9.0
    printf '/opt/airplanes/releases/v0.9.0\n' \
        > "$TARGET_ROOT/var/lib/airplanes/runtime/last-good-release"

    run sh "$SHIM_PATH"
    [ "$status" -eq 0 ]
    local cur
    cur="$(readlink "$TARGET_ROOT/opt/airplanes/current")"
    [ "$cur" = "/opt/airplanes/releases/v0.9.0" ]
}

# ---------------------------------------------------------------------------
# 3 failed attempts → needs_ssh (no reboot loop)
# ---------------------------------------------------------------------------
@test "shim: 3 failed recovery attempts triggers needs_ssh" {
    # No valid prev and no valid last-good → every attempt fails.
    shim_current "/opt/airplanes/releases/v_BROKEN"
    shim_state SYMLINK_FLIPPED \
        "prev_release=/opt/airplanes/releases/v_GONE" \
        "new_release=/opt/airplanes/releases/v_BROKEN"

    # Run 3 times.
    sh "$SHIM_PATH" 2>/dev/null || true
    sh "$SHIM_PATH" 2>/dev/null || true
    run sh "$SHIM_PATH"
    [ "$status" -ne 0 ]
    [ "$(shim_read_status)" = "needs_ssh" ]
    [[ "$(shim_read_state)" == NEEDS_SSH_* ]]
}

# ---------------------------------------------------------------------------
# Runs with overlay scripts corrupted (base-OS-only dependency)
# ---------------------------------------------------------------------------
@test "shim: runs even when install-common.sh is absent" {
    # No install-common.sh, no jq, no python anywhere under target root.
    # The shim must still function.
    local prev
    prev="$(shim_release 1.0.0)"
    shim_release 1.1.0
    shim_current "/opt/airplanes/releases/v1.1.0"
    shim_state HEALTH_RUNNING \
        "prev_release=/opt/airplanes/releases/v1.0.0" \
        "new_release=/opt/airplanes/releases/v1.1.0"

    # Deliberately do NOT have install-common.sh present.
    run sh "$SHIM_PATH"
    [ "$status" -eq 0 ]
    local cur
    cur="$(readlink "$TARGET_ROOT/opt/airplanes/current")"
    [ "$cur" = "/opt/airplanes/releases/v1.0.0" ]
}

# ---------------------------------------------------------------------------
# CLEAN / INSTALLED / FAILED_PRE_MUTATION are no-ops
# ---------------------------------------------------------------------------
@test "shim: CLEAN is a no-op" {
    run sh "$SHIM_PATH"
    [ "$status" -eq 0 ]
}

@test "shim: INSTALLED is a no-op" {
    shim_state INSTALLED
    run sh "$SHIM_PATH"
    [ "$status" -eq 0 ]
}

@test "shim: FAILED_PRE_MUTATION is a no-op" {
    shim_state FAILED_PRE_MUTATION "failure_reason=download_failed"
    run sh "$SHIM_PATH"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# STARTED / PAYLOAD_EXTRACTED: current never moved, clear state
# ---------------------------------------------------------------------------
@test "shim: STARTED clears state without rollback" {
    shim_release 1.0.0
    shim_current "/opt/airplanes/releases/v1.0.0"
    shim_state STARTED \
        "prev_release=/opt/airplanes/releases/v1.0.0"

    run sh "$SHIM_PATH"
    [ "$status" -eq 0 ]
    # State file should be gone (cleared).
    [ ! -e "$TARGET_ROOT/var/lib/airplanes/runtime-upgrade/upgrade-state" ]
}

# ---------------------------------------------------------------------------
# SYSTEMD_OPS_DONE flips back to prev (same as SYMLINK_FLIPPED)
# ---------------------------------------------------------------------------
@test "shim: SYSTEMD_OPS_DONE flips current back to prev_release" {
    shim_release 1.0.0
    shim_release 1.1.0
    shim_current "/opt/airplanes/releases/v1.1.0"
    shim_state SYSTEMD_OPS_DONE \
        "prev_release=/opt/airplanes/releases/v1.0.0" \
        "new_release=/opt/airplanes/releases/v1.1.0"

    run sh "$SHIM_PATH"
    [ "$status" -eq 0 ]
    local cur
    cur="$(readlink "$TARGET_ROOT/opt/airplanes/current")"
    [ "$cur" = "/opt/airplanes/releases/v1.0.0" ]
}

# ---------------------------------------------------------------------------
# valid_release rejects path traversal
# ---------------------------------------------------------------------------
@test "shim: valid_release rejects ../traversal" {
    shim_state SYMLINK_FLIPPED \
        "prev_release=/opt/airplanes/releases/v1.0.0/../../etc/shadow" \
        "new_release=/opt/airplanes/releases/v1.1.0"

    run sh "$SHIM_PATH"
    # Should fail (no valid target → retrying/needs_ssh depending on attempts)
    [ "$status" -ne 0 ] || [ "$(shim_read_status)" = "retrying" ]
}
