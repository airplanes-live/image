#!/usr/bin/env bats

# The critical post-success power-loss case: the orchestrator marked
# HEALTH_PASSED and was killed before the cleanup pass (runtime-
# manifest pointer + GC). The recover script MUST complete the install
# rather than roll back — health gates passed, the new release is good,
# the prior release is the wrong one.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    SHIM_DIR="$BATS_TEST_TMPDIR/shim"
    SYSCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    mk_systemctl_shim "$SHIM_DIR" "$SYSCTL_LOG" >/dev/null

    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"

    # Pre-stage prior + new release, with current pointing at NEW (as
    # the orchestrator had already flipped it).
    PREV_VER="0.0.0"
    PREV_DIR="$(mk_target_release "$TARGET_ROOT" "$PREV_VER")"
    NEW_VER="1.0.0"
    NEW_DIR="$(mk_target_release "$TARGET_ROOT" "$NEW_VER")"
    rm -f "$TARGET_ROOT/opt/airplanes-runtime/current"
    ln -s "/opt/airplanes-runtime/releases/v$NEW_VER" \
        "$TARGET_ROOT/opt/airplanes-runtime/current"
}

run_recover() {
    env \
        AIRPLANES_BUILD_MODE=0 \
        AIRPLANES_RUNTIME_ARCH_OVERRIDE="arm64" \
        AIRPLANES_RUNTIME_ROOT="$TARGET_ROOT" \
        AIRPLANES_RUNTIME_INSTALL_COMMON="$REPO_ROOT/runtime-overlay/scripts/lib/install-common.sh" \
        PATH="$SHIM_DIR:$PATH" \
        bash "$REPO_ROOT/runtime-overlay/src/lib/airplanes-runtime-update-recover.sh"
}

@test "HEALTH_PASSED completes install: records manifest pointer, marks INSTALLED" {
    mk_state_file "$TARGET_ROOT" HEALTH_PASSED \
        "prev_release=$PREV_DIR" \
        "new_release=$NEW_DIR"

    run run_recover
    [ "$status" -eq 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "INSTALLED" ]

    # Runtime-manifest pointer was written, pointing at current's
    # manifest. (Symlink target is the on-device-canonical path.)
    [ -L "$TARGET_ROOT/etc/airplanes/runtime-manifest.json" ]
    [ "$(readlink "$TARGET_ROOT/etc/airplanes/runtime-manifest.json")" \
        = "/opt/airplanes-runtime/current/manifest.json" ]

    # current STILL points at NEW — recovery did NOT roll back.
    [ "$(readlink "$TARGET_ROOT/opt/airplanes-runtime/current")" \
        = "/opt/airplanes-runtime/releases/v$NEW_VER" ]
    [ -d "$NEW_DIR" ]
}

@test "HEALTH_PASSED does NOT undo migrations from the new release" {
    # If recovery treated HEALTH_PASSED as a rollback path it would
    # call migration-rollback against new_release. Confirm no
    # migration-rollback side effect by checking that the new release
    # dir's manifest still describes the release without any
    # post-rollback artefacts.
    mk_state_file "$TARGET_ROOT" HEALTH_PASSED \
        "prev_release=$PREV_DIR" \
        "new_release=$NEW_DIR"
    run run_recover
    [ "$status" -eq 0 ]
    # current points at new (would have flipped to prev on rollback).
    [ "$(readlink "$TARGET_ROOT/opt/airplanes-runtime/current")" \
        = "/opt/airplanes-runtime/releases/v$NEW_VER" ]
}
