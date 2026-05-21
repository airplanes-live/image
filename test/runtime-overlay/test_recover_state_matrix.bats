#!/usr/bin/env bats

# State-recovery matrix: synthesise the upgrade-state file in each
# non-terminal state and invoke airplanes-runtime-update-recover.sh.
# Asserts the matrix row's action ran:
#   - new release dir cleaned up where appropriate
#   - current symlink reverted (or left) per the row's contract
#   - state file lands at a terminal value (CLEAN / INSTALLED /
#     ROLLED_BACK_*) the next orchestrator entry can clear

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    SHIM_DIR="$BATS_TEST_TMPDIR/shim"
    SYSCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    mk_systemctl_shim "$SHIM_DIR" "$SYSCTL_LOG" >/dev/null

    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"

    # Pre-stage a prior + new release dir. The recover script needs
    # both so its rollback flips current back to the prior one. The
    # tests that intentionally start with NO current (e.g. failed
    # first install) override these.
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

@test "CLEAN (absent state file) is a no-op" {
    # No state file synthesised.
    [ ! -e "$TARGET_ROOT/var/lib/airplanes-runtime-upgrade/upgrade-state" ]
    run run_recover
    [ "$status" -eq 0 ]
    # Still no state file written.
    [ ! -e "$TARGET_ROOT/var/lib/airplanes-runtime-upgrade/upgrade-state" ]
}

@test "STARTED clears state and drops scratch new release dir" {
    mk_state_file "$TARGET_ROOT" STARTED \
        "prev_release=$PREV_DIR" \
        "new_release=$NEW_DIR"
    run run_recover
    [ "$status" -eq 0 ]
    # State cleared back to CLEAN (no state file).
    [ ! -e "$TARGET_ROOT/var/lib/airplanes-runtime-upgrade/upgrade-state" ]
    # New release dir dropped (it existed before recovery).
    [ ! -d "$NEW_DIR" ]
}

@test "PAYLOAD_EXTRACTED removes new release dir and clears state" {
    mk_state_file "$TARGET_ROOT" PAYLOAD_EXTRACTED \
        "prev_release=$PREV_DIR" \
        "new_release=$NEW_DIR"
    run run_recover
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_ROOT/var/lib/airplanes-runtime-upgrade/upgrade-state" ]
    [ ! -d "$NEW_DIR" ]
    # Prior release dir untouched.
    [ -d "$PREV_DIR" ]
}

@test "MIGRATIONS_FORWARD_DONE undoes migrations, drops new, terminal ROLLED_BACK" {
    mk_state_file "$TARGET_ROOT" MIGRATIONS_FORWARD_DONE \
        "prev_release=$PREV_DIR" \
        "new_release=$NEW_DIR"
    run run_recover
    [ "$status" -eq 0 ]
    local state
    state="$(read_state "$TARGET_ROOT")"
    [[ "$state" == ROLLED_BACK_* ]]
    [ ! -d "$NEW_DIR" ]
    [ -d "$PREV_DIR" ]
}

@test "SYMLINK_FLIPPED flips current back to prior, undoes migrations, ROLLED_BACK" {
    # Set current symlink to NEW (as if the orchestrator had flipped it).
    rm -f "$TARGET_ROOT/opt/airplanes-runtime/current"
    ln -s "/opt/airplanes-runtime/releases/v$NEW_VER" \
        "$TARGET_ROOT/opt/airplanes-runtime/current"
    mk_state_file "$TARGET_ROOT" SYMLINK_FLIPPED \
        "prev_release=$PREV_DIR" \
        "new_release=$NEW_DIR"

    run run_recover
    [ "$status" -eq 0 ]
    local state
    state="$(read_state "$TARGET_ROOT")"
    [[ "$state" == ROLLED_BACK_* ]]
    # Current points back at prior release.
    [ "$(readlink "$TARGET_ROOT/opt/airplanes-runtime/current")" \
        = "/opt/airplanes-runtime/releases/v$PREV_VER" ]
    [ ! -d "$NEW_DIR" ]
    # daemon-reload was issued.
    grep -F 'daemon-reload' "$SYSCTL_LOG"
}

@test "SYSTEMD_OPS_DONE same as SYMLINK_FLIPPED" {
    rm -f "$TARGET_ROOT/opt/airplanes-runtime/current"
    ln -s "/opt/airplanes-runtime/releases/v$NEW_VER" \
        "$TARGET_ROOT/opt/airplanes-runtime/current"
    mk_state_file "$TARGET_ROOT" SYSTEMD_OPS_DONE \
        "prev_release=$PREV_DIR" \
        "new_release=$NEW_DIR"

    run run_recover
    [ "$status" -eq 0 ]
    [[ "$(read_state "$TARGET_ROOT")" == ROLLED_BACK_* ]]
    [ "$(readlink "$TARGET_ROOT/opt/airplanes-runtime/current")" \
        = "/opt/airplanes-runtime/releases/v$PREV_VER" ]
}

@test "HEALTH_RUNNING same as SYSTEMD_OPS_DONE — conservative rollback" {
    rm -f "$TARGET_ROOT/opt/airplanes-runtime/current"
    ln -s "/opt/airplanes-runtime/releases/v$NEW_VER" \
        "$TARGET_ROOT/opt/airplanes-runtime/current"
    mk_state_file "$TARGET_ROOT" HEALTH_RUNNING \
        "prev_release=$PREV_DIR" \
        "new_release=$NEW_DIR"

    run run_recover
    [ "$status" -eq 0 ]
    [[ "$(read_state "$TARGET_ROOT")" == ROLLED_BACK_* ]]
    [ "$(readlink "$TARGET_ROOT/opt/airplanes-runtime/current")" \
        = "/opt/airplanes-runtime/releases/v$PREV_VER" ]
}

@test "INSTALLED is a no-op (terminal good)" {
    mk_state_file "$TARGET_ROOT" INSTALLED \
        "prev_release=$PREV_DIR" \
        "new_release=$NEW_DIR"
    run run_recover
    [ "$status" -eq 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "INSTALLED" ]
}

@test "FAILED_PRE_MUTATION is a no-op" {
    mk_state_file "$TARGET_ROOT" FAILED_PRE_MUTATION \
        "failure_reason=download_failed"
    run run_recover
    [ "$status" -eq 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "FAILED_PRE_MUTATION" ]
}

@test "ROLLED_BACK_* is a no-op" {
    mk_state_file "$TARGET_ROOT" ROLLED_BACK_1.0.0_TO_0.0.0 \
        "failure_reason=health_gates_failed"
    run run_recover
    [ "$status" -eq 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "ROLLED_BACK_1.0.0_TO_0.0.0" ]
}

@test "UNKNOWN state file logs but leaves the file alone" {
    install -d -m 755 "$TARGET_ROOT/var/lib/airplanes-runtime-upgrade"
    printf 'corrupted\n' > "$TARGET_ROOT/var/lib/airplanes-runtime-upgrade/upgrade-state"
    run run_recover
    [ "$status" -eq 0 ]
    [[ "$output" == *"malformed"* ]]
    [ -e "$TARGET_ROOT/var/lib/airplanes-runtime-upgrade/upgrade-state" ]
}
