#!/usr/bin/env bats

# Hold the upgrade flock externally and confirm runtime-self-update.sh
# exits 75 without writing the state file. Mirrors the webconfig
# self-update helper's lock-contention behaviour.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    LOCK_DIR="$BATS_TEST_TMPDIR/lockdir"
    install -d -m 755 "$LOCK_DIR"
    LOCK_FILE="$LOCK_DIR/runtime-update.lock"
    # Pre-create the lock target so flock has something to claim.
    : > "$LOCK_FILE"
}

@test "concurrent invocation exits 75 without touching the state file" {
    # Hold the lock in a background shell.
    {
        exec 8>"$LOCK_FILE"
        flock 8
        # Signal that we hold the lock by touching a sentinel file.
        : > "$BATS_TEST_TMPDIR/lock-held"
        # Park until the test signals teardown.
        while [[ -e "$BATS_TEST_TMPDIR/keep-holding" ]]; do
            sleep 0.1
        done
        flock -u 8
    } &
    HOLDER_PID=$!
    : > "$BATS_TEST_TMPDIR/keep-holding"

    # Wait for the holder to acquire.
    local i
    for (( i = 0; i < 50; i++ )); do
        [[ -e "$BATS_TEST_TMPDIR/lock-held" ]] && break
        sleep 0.1
    done
    [[ -e "$BATS_TEST_TMPDIR/lock-held" ]] || {
        kill "$HOLDER_PID" 2>/dev/null || true
        return 1
    }

    # The state file must NOT exist beforehand — the contending invocation
    # writing one would corrupt this assertion.
    [ ! -e "$TARGET_ROOT/var/lib/airplanes/runtime-upgrade/upgrade-state" ]

    run env \
        AIRPLANES_BUILD_MODE=0 \
        AIRPLANES_RUNTIME_ARCH_OVERRIDE="arm64" \
        AIRPLANES_RUNTIME_ROOT="$TARGET_ROOT" \
        AIRPLANES_RUNTIME_LOCK_FILE="$LOCK_FILE" \
        AIRPLANES_RUNTIME_INSTALL_COMMON="$REPO_ROOT/runtime-overlay/scripts/lib/install-common.sh" \
        bash "$REPO_ROOT/runtime-overlay/src/lib/runtime-self-update.sh"

    [ "$status" -eq 75 ]
    [[ "$output" == *"another runtime-overlay update is in progress"* ]]
    # Critical: no state file written by the losing invocation.
    [ ! -e "$TARGET_ROOT/var/lib/airplanes/runtime-upgrade/upgrade-state" ]

    # Release the holder.
    rm -f "$BATS_TEST_TMPDIR/keep-holding"
    wait "$HOLDER_PID" 2>/dev/null || true
}
