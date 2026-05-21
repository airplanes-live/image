#!/usr/bin/env bats

# Tests config_kv migrations:
# - the target file is preimaged before mutation
# - missing key gets set; existing key with if_key_unset=true is skipped
# - rollback restores from preimage

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    RELEASE_DIR="$(mk_release_dir "$BATS_TEST_TMPDIR")"
    install -d -m 755 "$TARGET_ROOT/etc/default"
}

@test "config_kv writes the key when file is missing" {
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "mutable_paths": ["/etc/default/tar1090"],
    "migrations": [
        { "id": "tar1090-uat-key", "type": "config_kv",
          "run_when": "every_install",
          "file": "/etc/default/tar1090",
          "set": { "ENABLE_978": "no" } }
    ]
}
JSON
    run airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    run grep -E '^ENABLE_978=no$' "$TARGET_ROOT/etc/default/tar1090"
    [ "$status" -eq 0 ]
}

@test "config_kv updates an existing key in place" {
    printf 'ENABLE_978=yes\nFOO=bar\n' > "$TARGET_ROOT/etc/default/tar1090"
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "mutable_paths": ["/etc/default/tar1090"],
    "migrations": [
        { "id": "tar1090-uat-key", "type": "config_kv",
          "file": "/etc/default/tar1090",
          "set": { "ENABLE_978": "no" } }
    ]
}
JSON
    run airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    run grep -E '^ENABLE_978=no$' "$TARGET_ROOT/etc/default/tar1090"
    [ "$status" -eq 0 ]
    # FOO untouched.
    run grep -E '^FOO=bar$' "$TARGET_ROOT/etc/default/tar1090"
    [ "$status" -eq 0 ]
    # No double-line.
    run grep -c '^ENABLE_978=' "$TARGET_ROOT/etc/default/tar1090"
    [ "$output" = "1" ]
}

@test "if_key_unset honours an already-set key" {
    printf 'ENABLE_978=yes\n' > "$TARGET_ROOT/etc/default/tar1090"
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "mutable_paths": ["/etc/default/tar1090"],
    "migrations": [
        { "id": "tar1090-uat-key", "type": "config_kv",
          "file": "/etc/default/tar1090",
          "set": { "ENABLE_978": "no" },
          "if_key_unset": true }
    ]
}
JSON
    run airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    run grep -E '^ENABLE_978=yes$' "$TARGET_ROOT/etc/default/tar1090"
    [ "$status" -eq 0 ]
}

@test "rollback restores the file from preimage" {
    printf 'ENABLE_978=yes\n' > "$TARGET_ROOT/etc/default/tar1090"
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "mutable_paths": ["/etc/default/tar1090"],
    "migrations": [
        { "id": "tar1090-uat-key", "type": "config_kv",
          "file": "/etc/default/tar1090",
          "set": { "ENABLE_978": "no" } }
    ]
}
JSON
    airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    run grep -E '^ENABLE_978=no$' "$TARGET_ROOT/etc/default/tar1090"
    [ "$status" -eq 0 ]

    run airplanes_runtime_run_migrations_rollback "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    run grep -E '^ENABLE_978=yes$' "$TARGET_ROOT/etc/default/tar1090"
    [ "$status" -eq 0 ]
    # The migration id was removed from the applied list.
    if [[ -f "$TARGET_ROOT/etc/airplanes/runtime-migrations.applied" ]]; then
        run grep -F 'tar1090-uat-key' "$TARGET_ROOT/etc/airplanes/runtime-migrations.applied"
        [ "$status" -ne 0 ]
    fi
}

@test "first_install_of_version skips on re-run" {
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "mutable_paths": ["/etc/default/tar1090"],
    "migrations": [
        { "id": "tar1090-uat-key", "type": "config_kv",
          "run_when": "first_install_of_version",
          "file": "/etc/default/tar1090",
          "set": { "ENABLE_978": "no" } }
    ]
}
JSON
    airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    # Mutate the file post-apply to simulate operator change.
    printf 'ENABLE_978=yes\n' > "$TARGET_ROOT/etc/default/tar1090"
    # Re-run; the first_install_of_version gate should skip silently.
    run airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    run grep -E '^ENABLE_978=yes$' "$TARGET_ROOT/etc/default/tar1090"
    [ "$status" -eq 0 ]
}
