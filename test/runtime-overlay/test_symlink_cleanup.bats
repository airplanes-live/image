#!/usr/bin/env bats

# Tests for symlink cleanup on rollback (new-only removed) and on success
# (retired removed). Exercises the helpers in install-common.sh:
#   airplanes_runtime_remove_retired_symlinks
#   airplanes_runtime_remove_new_only_symlinks

bats_require_minimum_version 1.5.0

load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
}

# Helper: write a manifest with specified symlink-mode managed_paths links.
# Args: <dir> <link1> <link2> ...
mk_manifest_with_links() {
    local dir="$1"; shift
    local entries=""
    local first=1
    for link in "$@"; do
        [[ $first -eq 0 ]] && entries="$entries,"
        entries="$entries {\"mode\":\"symlink\",\"link\":\"$link\",\"target\":\"/opt/airplanes/current/bin/dummy\"}"
        first=0
    done
    cat > "$dir/manifest.json" <<JSON
{
    "manifest_schema_version": 1,
    "installer_min_version": "1.0.0",
    "version": "1.0.0",
    "channel": "stable",
    "commit_sha": "0000000000000000000000000000000000000000",
    "build_date": "2026-05-20T00:00:00Z",
    "arches": ["arm64"],
    "components": { "readsb_wiedehopf": "0000000" },
    "managed_paths": [ $entries ],
    "mutable_paths": [],
    "systemd": { "enable": [], "daemon_reload": true },
    "migrations": []
}
JSON
}

# ---------------------------------------------------------------------------
# Success: retired (old-only) symlinks are removed
# ---------------------------------------------------------------------------
@test "symlink cleanup: retired paths removed on success" {
    local prev_dir="$BATS_TEST_TMPDIR/prev"
    local new_dir="$BATS_TEST_TMPDIR/new"
    install -d "$prev_dir" "$new_dir"

    # prev has /usr/bin/old-tool and /usr/bin/shared-tool.
    # new  has /usr/bin/shared-tool and /usr/bin/new-tool.
    mk_manifest_with_links "$prev_dir" "/usr/bin/old-tool" "/usr/bin/shared-tool"
    mk_manifest_with_links "$new_dir"  "/usr/bin/shared-tool" "/usr/bin/new-tool"

    # Create the "old-tool" symlink on the target root.
    install -d -m 755 "$TARGET_ROOT/usr/bin"
    ln -s /opt/airplanes/current/bin/dummy "$TARGET_ROOT/usr/bin/old-tool"
    ln -s /opt/airplanes/current/bin/dummy "$TARGET_ROOT/usr/bin/shared-tool"

    airplanes_runtime_remove_retired_symlinks \
        "$prev_dir/manifest.json" "$new_dir/manifest.json" "$TARGET_ROOT"

    # old-tool (retired) should be gone.
    [ ! -e "$TARGET_ROOT/usr/bin/old-tool" ]
    # shared-tool (present in both) should remain.
    [ -L "$TARGET_ROOT/usr/bin/shared-tool" ]
}

# ---------------------------------------------------------------------------
# Rollback: new-only symlinks are removed
# ---------------------------------------------------------------------------
@test "symlink cleanup: new-only paths removed on rollback" {
    local prev_dir="$BATS_TEST_TMPDIR/prev"
    local new_dir="$BATS_TEST_TMPDIR/new"
    install -d "$prev_dir" "$new_dir"

    mk_manifest_with_links "$prev_dir" "/usr/bin/shared-tool"
    mk_manifest_with_links "$new_dir"  "/usr/bin/shared-tool" "/usr/bin/new-only-tool"

    # Create the new-only symlink on the target root (it was created by the
    # failed install's managed_paths apply before the rollback fires).
    install -d -m 755 "$TARGET_ROOT/usr/bin"
    ln -s /opt/airplanes/current/bin/dummy "$TARGET_ROOT/usr/bin/new-only-tool"
    ln -s /opt/airplanes/current/bin/dummy "$TARGET_ROOT/usr/bin/shared-tool"

    airplanes_runtime_remove_new_only_symlinks \
        "$new_dir/manifest.json" "$prev_dir/manifest.json" "$TARGET_ROOT"

    # new-only-tool should be gone.
    [ ! -e "$TARGET_ROOT/usr/bin/new-only-tool" ]
    # shared-tool should remain.
    [ -L "$TARGET_ROOT/usr/bin/shared-tool" ]
}

# ---------------------------------------------------------------------------
# Regular files at the link path are NOT removed (safety guard)
# ---------------------------------------------------------------------------
@test "symlink cleanup: regular file at link path is not removed" {
    local prev_dir="$BATS_TEST_TMPDIR/prev"
    local new_dir="$BATS_TEST_TMPDIR/new"
    install -d "$prev_dir" "$new_dir"

    mk_manifest_with_links "$prev_dir" "/usr/bin/operator-tool"
    mk_manifest_with_links "$new_dir"  # empty — everything in prev is "retired"

    # Create a real file (not a symlink) at the "retired" path.
    install -d -m 755 "$TARGET_ROOT/usr/bin"
    echo "operator content" > "$TARGET_ROOT/usr/bin/operator-tool"

    airplanes_runtime_remove_retired_symlinks \
        "$prev_dir/manifest.json" "$new_dir/manifest.json" "$TARGET_ROOT"

    # Must still be present — only symlinks are removed.
    [ -f "$TARGET_ROOT/usr/bin/operator-tool" ]
}

# ---------------------------------------------------------------------------
# No prev manifest (first install): no-op on success cleanup
# ---------------------------------------------------------------------------
@test "symlink cleanup: no-op when prev_manifest is missing" {
    local new_dir="$BATS_TEST_TMPDIR/new"
    install -d "$new_dir"
    mk_manifest_with_links "$new_dir" "/usr/bin/tool"

    # Calling with a nonexistent prev manifest should not error.
    run airplanes_runtime_remove_retired_symlinks \
        "/nonexistent/manifest.json" "$new_dir/manifest.json" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
}
