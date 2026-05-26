#!/usr/bin/env bats

# A HEALTH_PASSED state means a prior install's health gates passed but the
# cleanup/GC post-step was interrupted. The boot recovery shim only no-ops on
# HEALTH_PASSED (pointer recovery can't finish cleanup), so the NEXT
# invocation of runtime-self-update.sh must resume the cleanup before starting
# a fresh attempt. These tests exercise the resume-on-entry path and the
# install-common helpers it relies on.

bats_require_minimum_version 1.5.0

load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
}

@test "write_last_good_release records the device-canonical path" {
    airplanes_runtime_write_last_good_release "$TARGET_ROOT" \
        "/opt/airplanes-runtime/releases/v1.2.3"
    local f="$TARGET_ROOT/var/lib/airplanes-runtime/last-good-release"
    [ -f "$f" ]
    [ "$(head -n1 "$f")" = "/opt/airplanes-runtime/releases/v1.2.3" ]
}

@test "write_last_good_release rejects a relative path" {
    run airplanes_runtime_write_last_good_release "$TARGET_ROOT" "relative/path"
    [ "$status" -ne 0 ]
}

@test "finalize_after_health_passed writes the runtime-manifest pointer and GCs" {
    # Stage a release and point current at it so record_runtime_manifest can
    # resolve the manifest.
    local rel
    rel="$(mk_target_release "$TARGET_ROOT" 1.0.0)"
    rm -f "$TARGET_ROOT/opt/airplanes-runtime/current"
    ln -s "/opt/airplanes-runtime/releases/v1.0.0" \
        "$TARGET_ROOT/opt/airplanes-runtime/current"

    # Runtime mode (not build mode) so a symlink pointer is written.
    AIRPLANES_BUILD_MODE=0 \
        run airplanes_runtime_finalize_after_health_passed "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_ROOT/etc/airplanes/runtime-manifest.json" ]
}
