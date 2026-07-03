#!/usr/bin/env bats

# Tests for copy-mode managed_path preimage backup + restore.
# Ensures rollback reverts copy-mode files to their pre-install state.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    RELEASE_DIR="$(mk_release_dir "$BATS_TEST_TMPDIR")"
    # Stage a source file the manifest will reference.
    install -d -m 755 "$RELEASE_DIR/etc/sudoers.d"
    printf 'NEW_RELEASE grant\n' > "$RELEASE_DIR/etc/sudoers.d/090_airplanes-runtime"
}

_mk_copy_manifest() {
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "managed_paths": [
        { "mode": "copy",
          "path": "/etc/sudoers.d/090_airplanes-runtime",
          "from": "etc/sudoers.d/090_airplanes-runtime",
          "owner": "root:root",
          "perm": "0440" }
    ]
}
JSON
}

@test "backup captures existing file; restore reverts after clobber" {
    _mk_copy_manifest
    # Pre-existing destination content.
    install -d -m 755 "$TARGET_ROOT/etc/sudoers.d"
    printf 'ORIGINAL\n' > "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime"

    # Backup.
    run airplanes_runtime_backup_all_copy_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    # Preimage dir exists.
    [ -d "$RELEASE_DIR/.copy-preimage" ]

    # Clobber (simulate copy-mode apply writing the new release's file).
    printf 'NEW_RELEASE grant\n' > "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime"
    run cat "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime"
    [ "$output" = "NEW_RELEASE grant" ]

    # Restore.
    run airplanes_runtime_restore_all_copy_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    run cat "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime"
    [ "$output" = "ORIGINAL" ]
}

@test "backup marks absent; restore deletes file created by release" {
    _mk_copy_manifest
    # No pre-existing destination.

    # Backup (captures absent marker).
    run airplanes_runtime_backup_all_copy_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]

    # Release creates the file.
    install -d -m 755 "$TARGET_ROOT/etc/sudoers.d"
    printf 'NEW_RELEASE grant\n' > "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime"

    # Restore removes the file (it didn't exist before).
    run airplanes_runtime_restore_all_copy_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime" ]
}

@test "backup is write-once — second call does not clobber the original preimage" {
    _mk_copy_manifest
    install -d -m 755 "$TARGET_ROOT/etc/sudoers.d"
    printf 'ORIGINAL\n' > "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime"

    # First backup.
    run airplanes_runtime_backup_all_copy_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]

    # Mutate the live file.
    printf 'INTERMEDIATE\n' > "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime"

    # Second backup — must be a no-op (write-once).
    run airplanes_runtime_backup_all_copy_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]

    # Restore should give ORIGINAL, not INTERMEDIATE.
    printf 'CLOBBERED\n' > "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime"
    run airplanes_runtime_restore_all_copy_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    run cat "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime"
    [ "$output" = "ORIGINAL" ]
}

@test "symlink entries are ignored — only copy-mode paths are backed up" {
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "managed_paths": [
        { "mode": "symlink",
          "link": "/usr/bin/readsb",
          "target": "/opt/airplanes/current/bin/readsb" },
        { "mode": "copy",
          "path": "/etc/sudoers.d/090_airplanes-runtime",
          "from": "etc/sudoers.d/090_airplanes-runtime",
          "owner": "root:root",
          "perm": "0440" }
    ]
}
JSON
    install -d -m 755 "$TARGET_ROOT/etc/sudoers.d"
    printf 'ORIGINAL\n' > "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime"

    run airplanes_runtime_backup_all_copy_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    # Only the copy path should be backed up — no preimage for the symlink entry.
    local enc
    enc="$(_airplanes_runtime_encode_path "/usr/bin/readsb")"
    [ ! -e "$RELEASE_DIR/.copy-preimage/$enc" ]
    [ ! -e "$RELEASE_DIR/.copy-preimage/$enc.absent" ]
}
