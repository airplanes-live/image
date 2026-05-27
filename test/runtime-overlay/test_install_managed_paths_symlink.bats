#!/usr/bin/env bats

# Tests symlink-mode managed_paths application.
# - link points at an absolute /opt/airplanes-runtime/current/... target
# - the on-disk link target string MUST be the absolute manifest value, not
#   a relative one
# - the apply is atomic (the link is created via tmp + mv -Tf, never via
#   `ln -snf`)

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    RELEASE_DIR="$(mk_release_dir "$BATS_TEST_TMPDIR")"
}

write_manifest() {
    local path="$1"
    shift
    cat > "$path" <<'JSON'
{
    "version": "1.0.0",
    "channel": "stable",
    "managed_paths": [
        { "mode": "symlink", "link": "/etc/systemd/system/readsb.service",
          "target": "/opt/airplanes-runtime/current/systemd/readsb.service" },
        { "mode": "symlink", "link": "/usr/bin/airplanes-978",
          "target": "/opt/airplanes-runtime/current/bin/readsb" }
    ]
}
JSON
}

@test "symlinks are created with absolute targets" {
    write_manifest "$BATS_TEST_TMPDIR/manifest.json"
    run airplanes_runtime_apply_managed_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]

    [ -L "$TARGET_ROOT/etc/systemd/system/readsb.service" ]
    [ -L "$TARGET_ROOT/usr/bin/airplanes-978" ]

    run readlink "$TARGET_ROOT/etc/systemd/system/readsb.service"
    [ "$status" -eq 0 ]
    [ "$output" = "/opt/airplanes-runtime/current/systemd/readsb.service" ]

    run readlink "$TARGET_ROOT/usr/bin/airplanes-978"
    [ "$status" -eq 0 ]
    [ "$output" = "/opt/airplanes-runtime/current/bin/readsb" ]
}

@test "second apply atomically replaces an existing link" {
    write_manifest "$BATS_TEST_TMPDIR/manifest.json"
    # First apply.
    airplanes_runtime_apply_managed_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    # Tamper with the link to simulate a prior release.
    rm -f "$TARGET_ROOT/etc/systemd/system/readsb.service"
    ln -s /tmp/stale-target "$TARGET_ROOT/etc/systemd/system/readsb.service"
    # Re-apply.
    run airplanes_runtime_apply_managed_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    run readlink "$TARGET_ROOT/etc/systemd/system/readsb.service"
    [ "$status" -eq 0 ]
    [ "$output" = "/opt/airplanes-runtime/current/systemd/readsb.service" ]
}

@test "relative target string in manifest is rejected" {
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0",
    "channel": "stable",
    "managed_paths": [
        { "mode": "symlink", "link": "/etc/systemd/system/readsb.service",
          "target": "current/systemd/readsb.service" }
    ]
}
JSON
    run airplanes_runtime_apply_managed_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"absolute"* ]]
}

@test "no stale tmp file is left if apply succeeds" {
    write_manifest "$BATS_TEST_TMPDIR/manifest.json"
    airplanes_runtime_apply_managed_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    run find "$TARGET_ROOT" -name '*.tmp.*'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "apply replaces a pre-existing directory at the link path" {
    write_manifest "$BATS_TEST_TMPDIR/manifest.json"
    # Put a real directory where a managed symlink wants to land.
    install -d -m 755 "$TARGET_ROOT/etc/systemd/system/readsb.service"
    printf 'old\n' > "$TARGET_ROOT/etc/systemd/system/readsb.service/foo"

    run airplanes_runtime_apply_managed_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_ROOT/etc/systemd/system/readsb.service" ]
    [ "$(readlink "$TARGET_ROOT/etc/systemd/system/readsb.service")" = \
      "/opt/airplanes-runtime/current/systemd/readsb.service" ]
}

@test "apply replaces a pre-existing regular file at the link path" {
    write_manifest "$BATS_TEST_TMPDIR/manifest.json"
    install -d -m 755 "$TARGET_ROOT/etc/systemd/system"
    printf 'old unit\n' > "$TARGET_ROOT/etc/systemd/system/readsb.service"

    run airplanes_runtime_apply_managed_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_ROOT/etc/systemd/system/readsb.service" ]
}

@test "safety rail refuses to clear a critical system root" {
    run _airplanes_runtime_assert_safe_managed_path "/usr"
    [ "$status" -ne 0 ]
    [[ "$output" == *"critical system path"* ]]

    run _airplanes_runtime_assert_safe_managed_path "/"
    [ "$status" -ne 0 ]

    run _airplanes_runtime_assert_safe_managed_path ""
    [ "$status" -ne 0 ]

    # The overlay's own release tree is off-limits as a managed destination.
    run _airplanes_runtime_assert_safe_managed_path "/opt/airplanes-runtime/releases/v1.0.0"
    [ "$status" -ne 0 ]

    # A relative path is refused.
    run _airplanes_runtime_assert_safe_managed_path "usr/local/foo"
    [ "$status" -ne 0 ]

    # A deep managed path should pass.
    run _airplanes_runtime_assert_safe_managed_path "/usr/local/share/tar1090"
    [ "$status" -eq 0 ]
}
