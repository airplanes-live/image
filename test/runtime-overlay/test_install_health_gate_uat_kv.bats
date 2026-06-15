#!/usr/bin/env bats

# Tests the UAT (978) state-file gate's parser + decision matrix.
# The valid (state, reason) tuples must return 0; everything else must return
# non-zero before the per-check deadline. The valid set mirrors exactly what
# the dump978-fa (producer) and airplanes-978 (consumer) wrappers emit:
#   enabled|ok               active (decoding / relaying)
#   disabled|uat_disabled    978 off
#   disabled|no_hardware     producer self-disabled (978 SDR absent)
#   enabled|peer_no_hardware consumer relaying idle while producer has no SDR

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    AIRPLANES_RUNTIME_HEALTH_DEADLINE=1
    export AIRPLANES_RUNTIME_HEALTH_DEADLINE
    STATE_FILE="$BATS_TEST_TMPDIR/state"
}

@test "valid: state=enabled, reason=ok (active decode/relay)" {
    printf 'state=enabled\nreason=ok\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -eq 0 ]
}

@test "valid: state=disabled, reason=uat_disabled" {
    printf 'state=disabled\nreason=uat_disabled\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -eq 0 ]
}

@test "valid: state=disabled, reason=no_hardware (producer, 978 SDR absent)" {
    printf 'state=disabled\nreason=no_hardware\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -eq 0 ]
}

@test "valid: state=enabled, reason=peer_no_hardware (consumer relay idle)" {
    printf 'state=enabled\nreason=peer_no_hardware\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -eq 0 ]
}

# Regression guards: the gate used to accept these two, but no wrapper ever
# emits them — the active reason is "ok" (not empty) and the producer's
# no-hardware state is "disabled" (not "enabled"). A 978-decoding feeder wrote
# enabled|ok and the old gate timed out + rolled the whole overlay back.
@test "invalid: state=enabled, reason= (empty — wrappers emit ok, never empty)" {
    printf 'state=enabled\nreason=\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -ne 0 ]
}

@test "invalid: state=enabled, reason=no_hardware (producer self-disables instead)" {
    printf 'state=enabled\nreason=no_hardware\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -ne 0 ]
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
    printf '  state=enabled  \n  reason=ok  \nfoo=bar\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" "$AIRPLANES_RUNTIME_HEALTH_DEADLINE"
    [ "$status" -eq 0 ]
}

# Boundary: an already-valid file must be accepted even when the deadline has
# already elapsed on entry (deadline=0 forces now >= end on the first
# iteration). Guards against a deadline-first loop ordering that would time out
# without reading the file — the source of the intermittent CI flake.
@test "boundary: valid file accepted when deadline already elapsed" {
    printf 'state=enabled\nreason=ok\n' > "$STATE_FILE"
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" 0
    [ "$status" -eq 0 ]
}

@test "boundary: missing file still times out promptly at deadline=0" {
    run _airplanes_runtime_probe_uat_state "$STATE_FILE" 0
    [ "$status" -ne 0 ]
}
