#!/usr/bin/env bats

# Two consecutive invocations of the recovery script must converge: the
# first transitions the non-terminal state to its terminal label; the
# second runs the no-op branch for that terminal label.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    SHIM_DIR="$BATS_TEST_TMPDIR/shim"
    SYSCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    mk_systemctl_shim "$SHIM_DIR" "$SYSCTL_LOG" >/dev/null

    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    PREV_VER="0.0.0"
    PREV_DIR="$(mk_target_release "$TARGET_ROOT" "$PREV_VER")"
    NEW_VER="1.0.0"
    NEW_DIR="$(mk_target_release "$TARGET_ROOT" "$NEW_VER")"
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

@test "two consecutive recoveries from SYMLINK_FLIPPED converge to ROLLED_BACK_*" {
    rm -f "$TARGET_ROOT/opt/airplanes-runtime/current"
    ln -s "/opt/airplanes-runtime/releases/v$NEW_VER" \
        "$TARGET_ROOT/opt/airplanes-runtime/current"
    mk_state_file "$TARGET_ROOT" SYMLINK_FLIPPED \
        "prev_release=$PREV_DIR" \
        "new_release=$NEW_DIR"

    run run_recover
    [ "$status" -eq 0 ]
    local first_state
    first_state="$(read_state "$TARGET_ROOT")"
    [[ "$first_state" == ROLLED_BACK_* ]]

    # Second invocation: ROLLED_BACK_* is a no-op terminal state.
    run run_recover
    [ "$status" -eq 0 ]
    local second_state
    second_state="$(read_state "$TARGET_ROOT")"
    [ "$first_state" = "$second_state" ]
}

@test "two consecutive recoveries from HEALTH_PASSED converge to INSTALLED" {
    rm -f "$TARGET_ROOT/opt/airplanes-runtime/current"
    ln -s "/opt/airplanes-runtime/releases/v$NEW_VER" \
        "$TARGET_ROOT/opt/airplanes-runtime/current"
    mk_state_file "$TARGET_ROOT" HEALTH_PASSED \
        "prev_release=$PREV_DIR" \
        "new_release=$NEW_DIR"

    run run_recover
    [ "$status" -eq 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "INSTALLED" ]

    run run_recover
    [ "$status" -eq 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "INSTALLED" ]
}

@test "two consecutive recoveries from PAYLOAD_EXTRACTED converge to CLEAN (no file)" {
    mk_state_file "$TARGET_ROOT" PAYLOAD_EXTRACTED \
        "prev_release=$PREV_DIR" \
        "new_release=$NEW_DIR"

    run run_recover
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_ROOT/var/lib/airplanes-runtime-upgrade/upgrade-state" ]

    run run_recover
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_ROOT/var/lib/airplanes-runtime-upgrade/upgrade-state" ]
}
