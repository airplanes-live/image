#!/usr/bin/env bats

# Unit tests for the state-file helpers added to install-common.sh.
# The orchestrator + recovery script both rely on these for atomic state
# persistence; a regression here would corrupt every state transition.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
}

@test "state_read on missing file returns CLEAN" {
    run airplanes_runtime_state_read "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "CLEAN" ]
}

@test "state_write writes all keys and state_read returns the state" {
    airplanes_runtime_state_write "$TARGET_ROOT" STARTED \
        "prev_release=/opt/airplanes/releases/v1.0.0" \
        "new_release=/opt/airplanes/releases/v1.1.0" \
        "started_at=2026-05-20T00:00:00Z"
    run airplanes_runtime_state_read "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "STARTED" ]

    run airplanes_runtime_state_get "$TARGET_ROOT" prev_release
    [ "$output" = "/opt/airplanes/releases/v1.0.0" ]
    run airplanes_runtime_state_get "$TARGET_ROOT" new_release
    [ "$output" = "/opt/airplanes/releases/v1.1.0" ]
    run airplanes_runtime_state_get "$TARGET_ROOT" started_at
    [ "$output" = "2026-05-20T00:00:00Z" ]
}

@test "state_write preserves prev_release / new_release on subsequent transitions" {
    airplanes_runtime_state_write "$TARGET_ROOT" STARTED \
        "prev_release=/opt/airplanes/releases/v1.0.0" \
        "new_release=/opt/airplanes/releases/v1.1.0"
    airplanes_runtime_state_write "$TARGET_ROOT" PAYLOAD_EXTRACTED
    airplanes_runtime_state_write "$TARGET_ROOT" MIGRATIONS_FORWARD_DONE
    airplanes_runtime_state_write "$TARGET_ROOT" SYMLINK_FLIPPED

    run airplanes_runtime_state_read "$TARGET_ROOT"
    [ "$output" = "SYMLINK_FLIPPED" ]
    run airplanes_runtime_state_get "$TARGET_ROOT" prev_release
    [ "$output" = "/opt/airplanes/releases/v1.0.0" ]
    run airplanes_runtime_state_get "$TARGET_ROOT" new_release
    [ "$output" = "/opt/airplanes/releases/v1.1.0" ]
}

@test "state_write captures failure_reason on terminal failure" {
    airplanes_runtime_state_write "$TARGET_ROOT" FAILED_PRE_MUTATION \
        "failure_reason=compat_preflight_failed"
    run airplanes_runtime_state_get "$TARGET_ROOT" failure_reason
    [ "$output" = "compat_preflight_failed" ]
}

@test "state_clear removes the state file (next read returns CLEAN)" {
    airplanes_runtime_state_write "$TARGET_ROOT" STARTED
    airplanes_runtime_state_clear "$TARGET_ROOT"
    [ ! -e "$(airplanes_runtime_state_file "$TARGET_ROOT")" ]
    run airplanes_runtime_state_read "$TARGET_ROOT"
    [ "$output" = "CLEAN" ]
}

@test "state file rename is atomic — tmp file does not linger" {
    airplanes_runtime_state_write "$TARGET_ROOT" STARTED
    # Confirm no leftover .tmp.PID file in the state dir.
    run find "$(airplanes_runtime_state_dir "$TARGET_ROOT")" -name '*.tmp.*' -print
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "state_read on malformed file returns UNKNOWN" {
    install -d -m 755 "$TARGET_ROOT/var/lib/airplanes/runtime-upgrade"
    printf 'this is not a state file\n' \
        > "$TARGET_ROOT/var/lib/airplanes/runtime-upgrade/upgrade-state"
    run airplanes_runtime_state_read "$TARGET_ROOT"
    [ "$output" = "UNKNOWN" ]
}

@test "state file mode is 0644" {
    airplanes_runtime_state_write "$TARGET_ROOT" STARTED
    local f
    f="$(airplanes_runtime_state_file "$TARGET_ROOT")"
    run stat -c '%a' "$f"
    [ "$output" = "644" ]
}

@test "state_write returns non-zero when the parent dir is read-only" {
    # Remove the state dir BEFORE locking the parent so ensure_state_dir's
    # install -d fails. ensure_state_dir's `install -d -m 755` overrides
    # any chmod we apply to the state dir directly, so we must break
    # the next-higher level instead. The state dir is now nested two deep
    # (/var/lib/airplanes/runtime-upgrade), and /var/lib/airplanes already
    # exists writable, so locking /var/lib no longer blocks the leaf — lock
    # the immediate parent /var/lib/airplanes instead.
    mkdir -p "$TARGET_ROOT/var/lib/airplanes"
    rm -rf "$TARGET_ROOT/var/lib/airplanes/runtime-upgrade"
    chmod 0555 "$TARGET_ROOT/var/lib/airplanes"

    run airplanes_runtime_state_write "$TARGET_ROOT" STARTED
    rc=$status
    chmod 0755 "$TARGET_ROOT/var/lib/airplanes"

    [ "$rc" -ne 0 ]
}

@test "state_write rejects unknown key=value pairs" {
    run airplanes_runtime_state_write "$TARGET_ROOT" STARTED \
        "unknown_key=value"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown kv pair"* ]]
}
