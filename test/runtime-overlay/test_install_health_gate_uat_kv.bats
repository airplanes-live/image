#!/usr/bin/env bats

# Tests the UAT (978) state-file gate's parser + decision matrix.
# The four valid (state, reason) tuples must return 0; everything else
# must return non-zero before the per-check deadline.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    AIRPLANES_RUNTIME_HEALTH_DEADLINE=1
    export AIRPLANES_RUNTIME_HEALTH_DEADLINE
    STATE_FILE="$BATS_TEST_TMPDIR/state"
}

@test "valid: state=enabled, reason=" {
    printf 'state=enabled\nreason=\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -eq 0 ]
}

@test "valid: state=disabled, reason=uat_disabled" {
    printf 'state=disabled\nreason=uat_disabled\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -eq 0 ]
}

@test "valid: state=enabled, reason=no_hardware" {
    printf 'state=enabled\nreason=no_hardware\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -eq 0 ]
}

@test "valid: state=enabled, reason=peer_no_hardware" {
    printf 'state=enabled\nreason=peer_no_hardware\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -eq 0 ]
}

@test "invalid: state=disabled, reason= (empty reason for disabled)" {
    printf 'state=disabled\nreason=\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -ne 0 ]
}

@test "invalid: state=enabled, reason=mystery_value" {
    printf 'state=enabled\nreason=mystery_value\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -ne 0 ]
}

@test "invalid: state=failing, reason=" {
    printf 'state=failing\nreason=\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -ne 0 ]
}

@test "invalid: missing file" {
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -ne 0 ]
}

@test "invalid: empty file" {
    : > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -ne 0 ]
}

@test "parser ignores whitespace + extra lines" {
    printf '  state=enabled  \n  reason=  \nfoo=bar\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -eq 0 ]
}
