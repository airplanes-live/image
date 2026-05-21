#!/usr/bin/env bats

# Tests airplanes_runtime_backup_mutable_path's write-once semantics +
# rollback correctness across the multi-migration case.
#
# Background: when the install pipeline backs up all mutable_paths up-front
# and a subsequent config_kv migration ALSO calls backup on the same file,
# the second backup must not overwrite the first one — otherwise rollback
# restores from a half-mutated intermediate, not the true pre-install
# state.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    RELEASE_DIR="$(mk_release_dir "$BATS_TEST_TMPDIR")"
}

@test "backup is write-once: second call leaves the first preimage intact" {
    install -d -m 755 "$TARGET_ROOT/etc/default"
    printf 'ENABLE_978=yes\n' > "$TARGET_ROOT/etc/default/tar1090"

    # First backup captures the original content.
    airplanes_runtime_backup_mutable_path "$RELEASE_DIR" "$TARGET_ROOT" "/etc/default/tar1090"

    # Mutate the file (simulating an earlier migration step).
    printf 'ENABLE_978=no\n' > "$TARGET_ROOT/etc/default/tar1090"

    # Second backup must NOT clobber the preimage with the mutated value.
    airplanes_runtime_backup_mutable_path "$RELEASE_DIR" "$TARGET_ROOT" "/etc/default/tar1090"

    # Restore — should recover the ORIGINAL "ENABLE_978=yes", not "no".
    airplanes_runtime_restore_mutable_path "$RELEASE_DIR" "$TARGET_ROOT" "/etc/default/tar1090"
    run grep -E '^ENABLE_978=yes$' "$TARGET_ROOT/etc/default/tar1090"
    [ "$status" -eq 0 ]
}

@test "two config_kv migrations on the same file share one preimage" {
    install -d -m 755 "$TARGET_ROOT/etc/default"
    printf 'FOO=a\nBAR=b\n' > "$TARGET_ROOT/etc/default/test"

    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "mutable_paths": ["/etc/default/test"],
    "migrations": [
        { "id": "set-foo", "type": "config_kv",
          "file": "/etc/default/test",
          "set": { "FOO": "new-foo" } },
        { "id": "set-bar", "type": "config_kv",
          "file": "/etc/default/test",
          "set": { "BAR": "new-bar" } }
    ]
}
JSON
    run airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    run grep -E '^FOO=new-foo$' "$TARGET_ROOT/etc/default/test"
    [ "$status" -eq 0 ]
    run grep -E '^BAR=new-bar$' "$TARGET_ROOT/etc/default/test"
    [ "$status" -eq 0 ]

    # Rollback should restore ORIGINAL "FOO=a\nBAR=b\n", not the
    # intermediate "FOO=new-foo\nBAR=b" the second-migration backup would
    # have captured under broken semantics.
    run airplanes_runtime_run_migrations_rollback "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    run grep -E '^FOO=a$' "$TARGET_ROOT/etc/default/test"
    [ "$status" -eq 0 ]
    run grep -E '^BAR=b$' "$TARGET_ROOT/etc/default/test"
    [ "$status" -eq 0 ]
}

@test "absent-marker is also write-once across repeated calls" {
    # File doesn't exist initially. First backup writes the .absent marker.
    airplanes_runtime_backup_mutable_path "$RELEASE_DIR" "$TARGET_ROOT" "/etc/default/maybe"
    install -d -m 755 "$TARGET_ROOT/etc/default"
    # The runtime then creates the file (simulating the migration that
    # introduced it).
    printf 'NEW=value\n' > "$TARGET_ROOT/etc/default/maybe"
    # A second backup is a no-op: the absent-marker must be preserved.
    airplanes_runtime_backup_mutable_path "$RELEASE_DIR" "$TARGET_ROOT" "/etc/default/maybe"
    # Rollback removes the now-created file.
    airplanes_runtime_restore_mutable_path "$RELEASE_DIR" "$TARGET_ROOT" "/etc/default/maybe"
    [ ! -e "$TARGET_ROOT/etc/default/maybe" ]
}
