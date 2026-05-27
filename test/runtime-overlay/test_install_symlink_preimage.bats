#!/usr/bin/env bats

# Tests for symlink-mode managed_path preimage backup + restore.
# Ensures rollback recovers original content at symlink-managed link paths,
# covering directories, regular files, symlinks (including dangling), absent
# paths, and the write-once / atomic-staging invariants.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    RELEASE_DIR="$(mk_release_dir "$BATS_TEST_TMPDIR")"
}

_mk_symlink_manifest() {
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "managed_paths": [
        { "mode": "symlink",
          "link": "/usr/local/share/tar1090",
          "target": "/opt/airplanes-runtime/current/share/tar1090" }
    ]
}
JSON
}

@test "backup captures pre-existing directory; restore reverts after symlink replace" {
    _mk_symlink_manifest
    install -d -m 755 "$TARGET_ROOT/usr/local/share/tar1090"
    printf 'index\n' > "$TARGET_ROOT/usr/local/share/tar1090/index.html"

    run airplanes_runtime_backup_all_symlink_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ -d "$RELEASE_DIR/.symlink-preimage" ]

    # Simulate apply: rm the dir and place a symlink.
    rm -rf "$TARGET_ROOT/usr/local/share/tar1090"
    ln -s /opt/airplanes-runtime/current/share/tar1090 \
        "$TARGET_ROOT/usr/local/share/tar1090"

    run airplanes_runtime_restore_all_symlink_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ -d "$TARGET_ROOT/usr/local/share/tar1090" ]
    [ ! -L "$TARGET_ROOT/usr/local/share/tar1090" ]
    grep 'index' "$TARGET_ROOT/usr/local/share/tar1090/index.html"
}

@test "backup captures pre-existing regular file; restore reverts" {
    _mk_symlink_manifest
    install -d -m 755 "$TARGET_ROOT/usr/local/share"
    printf 'original binary\n' > "$TARGET_ROOT/usr/local/share/tar1090"

    airplanes_runtime_backup_all_symlink_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    # Simulate apply: mv -Tf replaces a regular file.
    rm -f "$TARGET_ROOT/usr/local/share/tar1090"
    ln -s /target "$TARGET_ROOT/usr/local/share/tar1090"

    airplanes_runtime_restore_all_symlink_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ -f "$TARGET_ROOT/usr/local/share/tar1090" ]
    [ ! -L "$TARGET_ROOT/usr/local/share/tar1090" ]
    grep 'original binary' "$TARGET_ROOT/usr/local/share/tar1090"
}

@test "backup captures pre-existing symlink; restore reverts changed target" {
    _mk_symlink_manifest
    install -d -m 755 "$TARGET_ROOT/usr/local/share"
    ln -s /old-target "$TARGET_ROOT/usr/local/share/tar1090"

    airplanes_runtime_backup_all_symlink_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    # Simulate apply: replaces with a new target.
    rm -f "$TARGET_ROOT/usr/local/share/tar1090"
    ln -s /new-target "$TARGET_ROOT/usr/local/share/tar1090"

    airplanes_runtime_restore_all_symlink_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ -L "$TARGET_ROOT/usr/local/share/tar1090" ]
    [ "$(readlink "$TARGET_ROOT/usr/local/share/tar1090")" = "/old-target" ]
}

@test "backup captures dangling symlink; restore reverts" {
    _mk_symlink_manifest
    install -d -m 755 "$TARGET_ROOT/usr/local/share"
    ln -s /nonexistent "$TARGET_ROOT/usr/local/share/tar1090"
    # Dangling: target doesn't exist, -e is false, but -L is true.
    [ ! -e "$TARGET_ROOT/usr/local/share/tar1090" ]
    [ -L "$TARGET_ROOT/usr/local/share/tar1090" ]

    airplanes_runtime_backup_all_symlink_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    rm -f "$TARGET_ROOT/usr/local/share/tar1090"
    ln -s /replaced "$TARGET_ROOT/usr/local/share/tar1090"

    airplanes_runtime_restore_all_symlink_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ -L "$TARGET_ROOT/usr/local/share/tar1090" ]
    [ "$(readlink "$TARGET_ROOT/usr/local/share/tar1090")" = "/nonexistent" ]
}

@test "backup marks absent; restore removes the new symlink" {
    _mk_symlink_manifest
    # Path does not exist at all before install.
    [ ! -e "$TARGET_ROOT/usr/local/share/tar1090" ]

    airplanes_runtime_backup_all_symlink_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    # Simulate first-time install: created by apply.
    install -d -m 755 "$TARGET_ROOT/usr/local/share"
    ln -s /opt/airplanes-runtime/current/share/tar1090 \
        "$TARGET_ROOT/usr/local/share/tar1090"

    airplanes_runtime_restore_all_symlink_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ ! -e "$TARGET_ROOT/usr/local/share/tar1090" ]
    [ ! -L "$TARGET_ROOT/usr/local/share/tar1090" ]
}

@test "write-once: second backup does not clobber the original preimage" {
    _mk_symlink_manifest
    install -d -m 755 "$TARGET_ROOT/usr/local/share"
    printf 'ORIGINAL\n' > "$TARGET_ROOT/usr/local/share/tar1090"

    airplanes_runtime_backup_all_symlink_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    # Mutate the live path (simulate apply or external change).
    printf 'INTERMEDIATE\n' > "$TARGET_ROOT/usr/local/share/tar1090"
    # Second backup — no-op due to write-once.
    airplanes_runtime_backup_all_symlink_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    # Clobber again, then restore.
    printf 'CLOBBERED\n' > "$TARGET_ROOT/usr/local/share/tar1090"

    airplanes_runtime_restore_all_symlink_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    grep 'ORIGINAL' "$TARGET_ROOT/usr/local/share/tar1090"
}

@test "atomic backup: partial copy never yields a valid-looking preimage" {
    _mk_symlink_manifest
    install -d -m 755 "$TARGET_ROOT/usr/local/share"
    printf 'content\n' > "$TARGET_ROOT/usr/local/share/tar1090"

    # A successful backup produces the encoded file, never a .tmp.* leftover.
    airplanes_runtime_backup_all_symlink_paths \
        "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"

    local enc
    enc="$(_airplanes_runtime_encode_path "/usr/local/share/tar1090")"
    [ -e "$RELEASE_DIR/.symlink-preimage/$enc" ]
    # No temp artifacts in the preimage dir.
    run find "$RELEASE_DIR/.symlink-preimage" -name '*.tmp.*'
    [ -z "$output" ]
}
