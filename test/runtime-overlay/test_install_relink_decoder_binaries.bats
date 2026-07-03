#!/usr/bin/env bats

# Tests airplanes_runtime_relink_decoder_binaries:
# - Two operator shims under /usr/local/bin — readsb and dump978-fa — each
#   point at their OWN binary under /opt/airplanes/current/bin/.
# - The old /usr/bin/{readsb,airplanes-978} squat aliases are no longer
#   created (the airplanes-978 PATH alias is dropped; the wrapper uses
#   exec -a internally).
# - The relink is atomic (no .tmp leftovers, no race window).
# - Re-running replaces stale prior targets cleanly.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
}

@test "creates both operator shims under /usr/local/bin pointing at their own current/bin binary" {
    run airplanes_runtime_relink_decoder_binaries "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_ROOT/usr/local/bin/readsb" ]
    [ -L "$TARGET_ROOT/usr/local/bin/dump978-fa" ]
    [ "$(readlink "$TARGET_ROOT/usr/local/bin/readsb")" = "/opt/airplanes/current/bin/readsb" ]
    [ "$(readlink "$TARGET_ROOT/usr/local/bin/dump978-fa")" = "/opt/airplanes/current/bin/dump978-fa" ]
    # The dropped squat aliases must not be created.
    [ ! -e "$TARGET_ROOT/usr/bin/readsb" ]
    [ ! -e "$TARGET_ROOT/usr/bin/airplanes-978" ]
}

@test "atomic-replaces a stale prior target" {
    # Seed with a stale link pointing somewhere else.
    install -d -m 755 "$TARGET_ROOT/usr/local/bin"
    rm -f "$TARGET_ROOT/usr/local/bin/readsb"
    ln -s "/tmp/stale" "$TARGET_ROOT/usr/local/bin/readsb"
    run airplanes_runtime_relink_decoder_binaries "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ "$(readlink "$TARGET_ROOT/usr/local/bin/readsb")" = "/opt/airplanes/current/bin/readsb" ]
}

@test "leaves no .tmp leftovers under /usr/local/bin/" {
    airplanes_runtime_relink_decoder_binaries "$TARGET_ROOT"
    run find "$TARGET_ROOT/usr/local/bin" -name '*.tmp.*'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "each shim points at its own distinct binary after flip" {
    airplanes_runtime_relink_decoder_binaries "$TARGET_ROOT"
    # Read the link strings — they're absolute and point at different binaries.
    [ "$(readlink "$TARGET_ROOT/usr/local/bin/readsb")" = "/opt/airplanes/current/bin/readsb" ]
    [ "$(readlink "$TARGET_ROOT/usr/local/bin/dump978-fa")" = "/opt/airplanes/current/bin/dump978-fa" ]
    [ "$(readlink "$TARGET_ROOT/usr/local/bin/readsb")" != \
      "$(readlink "$TARGET_ROOT/usr/local/bin/dump978-fa")" ]
}
