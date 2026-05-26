#!/usr/bin/env bats

# Assert runtime-self-update.sh refuses to enter when the state file is in
# a mid-flip non-terminal state. The boot recovery shim is responsible for
# draining a half-flipped state before the orchestrator runs again; mixing
# entry paths is error-prone, so the orchestrator fails loudly. HEALTH_PASSED
# is the one resumable exception — covered by its own test, not here.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    LOCK_DIR="$BATS_TEST_TMPDIR/lockdir"
    install -d -m 755 "$LOCK_DIR"
    LOCK_FILE="$LOCK_DIR/runtime-update.lock"
}

run_self_update() {
    env \
        AIRPLANES_BUILD_MODE=0 \
        AIRPLANES_RUNTIME_ARCH_OVERRIDE="arm64" \
        AIRPLANES_RUNTIME_ROOT="$TARGET_ROOT" \
        AIRPLANES_RUNTIME_LOCK_FILE="$LOCK_FILE" \
        AIRPLANES_RUNTIME_INSTALL_COMMON="$REPO_ROOT/runtime-overlay/scripts/lib/install-common.sh" \
        bash "$REPO_ROOT/runtime-overlay/src/lib/runtime-self-update.sh"
}

@test "refuses entry when state is STARTED" {
    mk_state_file "$TARGET_ROOT" STARTED \
        "prev_release=" \
        "new_release=$TARGET_ROOT/opt/airplanes-runtime/releases/v1.0.0"
    run run_self_update
    [ "$status" -ne 0 ]
    [[ "$output" == *"non-terminal state"* ]]
    [[ "$output" == *"boot recovery shim"* ]]
    # State file untouched.
    [ "$(read_state "$TARGET_ROOT")" = "STARTED" ]
}

@test "refuses entry when state is PAYLOAD_EXTRACTED" {
    mk_state_file "$TARGET_ROOT" PAYLOAD_EXTRACTED
    run run_self_update
    [ "$status" -ne 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "PAYLOAD_EXTRACTED" ]
}

@test "refuses entry when state is MIGRATIONS_FORWARD_DONE" {
    mk_state_file "$TARGET_ROOT" MIGRATIONS_FORWARD_DONE
    run run_self_update
    [ "$status" -ne 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "MIGRATIONS_FORWARD_DONE" ]
}

@test "refuses entry when state is SYMLINK_FLIPPED" {
    mk_state_file "$TARGET_ROOT" SYMLINK_FLIPPED
    run run_self_update
    [ "$status" -ne 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "SYMLINK_FLIPPED" ]
}

@test "refuses entry when state is SYSTEMD_OPS_DONE" {
    mk_state_file "$TARGET_ROOT" SYSTEMD_OPS_DONE
    run run_self_update
    [ "$status" -ne 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "SYSTEMD_OPS_DONE" ]
}

@test "refuses entry when state is HEALTH_RUNNING" {
    mk_state_file "$TARGET_ROOT" HEALTH_RUNNING
    run run_self_update
    [ "$status" -ne 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "HEALTH_RUNNING" ]
}

@test "refuses entry when state file is malformed (UNKNOWN)" {
    install -d -m 755 "$TARGET_ROOT/var/lib/airplanes-runtime-upgrade"
    printf 'this is corrupted\n' \
        > "$TARGET_ROOT/var/lib/airplanes-runtime-upgrade/upgrade-state"
    run run_self_update
    [ "$status" -ne 0 ]
    [[ "$output" == *"malformed"* ]]
}
