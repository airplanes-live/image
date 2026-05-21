#!/usr/bin/env bats

# Tests airplanes_runtime_relink_decoder_binaries:
# - Both /usr/bin/readsb and /usr/bin/airplanes-978 end up as symlinks to
#   /opt/airplanes-runtime/current/bin/readsb (decision 14).
# - The relink is atomic (no .tmp leftovers, no race window).
# - Re-running replaces stale prior targets cleanly.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
}

@test "creates both symlinks pointing at current/bin/readsb" {
    run airplanes_runtime_relink_decoder_binaries "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_ROOT/usr/bin/readsb" ]
    [ -L "$TARGET_ROOT/usr/bin/airplanes-978" ]
    [ "$(readlink "$TARGET_ROOT/usr/bin/readsb")" = "/opt/airplanes-runtime/current/bin/readsb" ]
    [ "$(readlink "$TARGET_ROOT/usr/bin/airplanes-978")" = "/opt/airplanes-runtime/current/bin/readsb" ]
}

@test "atomic-replaces a stale prior target" {
    # Seed with a stale link pointing somewhere else.
    rm -f "$TARGET_ROOT/usr/bin/readsb"
    ln -s "/tmp/stale" "$TARGET_ROOT/usr/bin/readsb"
    run airplanes_runtime_relink_decoder_binaries "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ "$(readlink "$TARGET_ROOT/usr/bin/readsb")" = "/opt/airplanes-runtime/current/bin/readsb" ]
}

@test "leaves no .tmp leftovers under /usr/bin/" {
    airplanes_runtime_relink_decoder_binaries "$TARGET_ROOT"
    run find "$TARGET_ROOT/usr/bin" -name '*.tmp.*'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "both links share the same physical target after flip" {
    airplanes_runtime_relink_decoder_binaries "$TARGET_ROOT"
    # Read the link strings — they're absolute and identical.
    [ "$(readlink "$TARGET_ROOT/usr/bin/readsb")" = \
      "$(readlink "$TARGET_ROOT/usr/bin/airplanes-978")" ]
}
