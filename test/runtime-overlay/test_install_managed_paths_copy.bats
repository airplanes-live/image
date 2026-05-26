#!/usr/bin/env bats

# Tests copy-mode managed_paths application.
# - file is copied from release dir to absolute FHS path
# - declared `perm` is applied (mode-only assertion since owner needs root)
# - `post_install` argv runs sequentially; failure aborts
# - existing files are atomically replaced via tmp + mv

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    RELEASE_DIR="$(mk_release_dir "$BATS_TEST_TMPDIR")"
    # Pre-stage the source file the manifest will reference.
    install -d -m 755 "$RELEASE_DIR/etc/sudoers.d"
    cat > "$RELEASE_DIR/etc/sudoers.d/090_airplanes-runtime" <<'SUDO'
# airplanes-runtime sudoers grants
airplanes-runtime ALL=(ALL) NOPASSWD: /bin/true
SUDO
}

@test "copy mode lays the file at the declared path with declared mode" {
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
    run airplanes_runtime_apply_managed_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ -f "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime" ]
    # Verify content round-trip.
    run grep -q 'airplanes-runtime ALL=(ALL)' "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime"
    [ "$status" -eq 0 ]
    # Mode-only check (owner needs root; the helper auto-skips chown when not root).
    local mode
    mode="$(stat -c '%a' "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime")"
    [ "$mode" = "440" ]
}

@test "post_install argv runs successfully" {
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "managed_paths": [
        { "mode": "copy",
          "path": "/etc/sudoers.d/090_airplanes-runtime",
          "from": "etc/sudoers.d/090_airplanes-runtime",
          "owner": "root:root",
          "perm": "0440",
          "post_install": ["/bin/true"] }
    ]
}
JSON
    run airplanes_runtime_apply_managed_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
}

@test "post_install argv failure aborts the apply" {
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "managed_paths": [
        { "mode": "copy",
          "path": "/etc/sudoers.d/090_airplanes-runtime",
          "from": "etc/sudoers.d/090_airplanes-runtime",
          "owner": "root:root",
          "perm": "0440",
          "post_install": ["/bin/false"] }
    ]
}
JSON
    run airplanes_runtime_apply_managed_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"post_install failed"* ]]
}

@test "post_install failure prevents file from going live (validate-before-mv)" {
    # A validator that rejects files containing BROKEN — proves the staged
    # tmp is validated, not the destination (which does not exist yet).
    cat > "$BATS_TEST_TMPDIR/validator" <<'VAL'
#!/usr/bin/env bash
# Usage: validator -cf <file>
f="${2:?}"
! grep -q BROKEN "$f"
VAL
    chmod +x "$BATS_TEST_TMPDIR/validator"
    # Stage a BROKEN source.
    printf 'BROKEN content\n' > "$RELEASE_DIR/etc/sudoers.d/090_airplanes-runtime"
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<JSON
{
    "version": "1.0.0", "channel": "stable",
    "managed_paths": [
        { "mode": "copy",
          "path": "/etc/sudoers.d/090_airplanes-runtime",
          "from": "etc/sudoers.d/090_airplanes-runtime",
          "owner": "root:root",
          "perm": "0440",
          "post_install": ["$BATS_TEST_TMPDIR/validator", "-cf", "/etc/sudoers.d/090_airplanes-runtime"] }
    ]
}
JSON
    run airplanes_runtime_apply_managed_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"post_install failed"* ]]
    # The invalid file MUST NOT exist at the destination.
    [ ! -e "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime" ]
}

@test "post_install validates staged tmp, not destination (path substitution)" {
    # Validator that echoes its -cf argument — we assert the path was the
    # tmp file, not the manifest-declared path.
    cat > "$BATS_TEST_TMPDIR/validator" <<'VAL'
#!/usr/bin/env bash
echo "validated: $2"
VAL
    chmod +x "$BATS_TEST_TMPDIR/validator"
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<JSON
{
    "version": "1.0.0", "channel": "stable",
    "managed_paths": [
        { "mode": "copy",
          "path": "/etc/sudoers.d/090_airplanes-runtime",
          "from": "etc/sudoers.d/090_airplanes-runtime",
          "owner": "root:root",
          "perm": "0440",
          "post_install": ["$BATS_TEST_TMPDIR/validator", "-cf", "/etc/sudoers.d/090_airplanes-runtime"] }
    ]
}
JSON
    run airplanes_runtime_apply_managed_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    # The validated path must contain ".tmp." — the staged tmp, not the
    # bare destination. This proves path substitution happened.
    [[ "$output" == *".tmp."* ]]
}

@test "pre-existing destination preserved when post_install rejects the new file" {
    # Place a valid file at the destination.
    install -d -m 755 "$TARGET_ROOT/etc/sudoers.d"
    printf 'ORIGINAL\n' > "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime"
    # Stage a BROKEN source.
    printf 'BROKEN content\n' > "$RELEASE_DIR/etc/sudoers.d/090_airplanes-runtime"
    cat > "$BATS_TEST_TMPDIR/validator" <<'VAL'
#!/usr/bin/env bash
f="${2:?}"
! grep -q BROKEN "$f"
VAL
    chmod +x "$BATS_TEST_TMPDIR/validator"
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<JSON
{
    "version": "1.0.0", "channel": "stable",
    "managed_paths": [
        { "mode": "copy",
          "path": "/etc/sudoers.d/090_airplanes-runtime",
          "from": "etc/sudoers.d/090_airplanes-runtime",
          "owner": "root:root",
          "perm": "0440",
          "post_install": ["$BATS_TEST_TMPDIR/validator", "-cf", "/etc/sudoers.d/090_airplanes-runtime"] }
    ]
}
JSON
    run airplanes_runtime_apply_managed_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    # The original must still be intact.
    run cat "$TARGET_ROOT/etc/sudoers.d/090_airplanes-runtime"
    [ "$output" = "ORIGINAL" ]
}

@test "missing source file is rejected with a clear error" {
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "managed_paths": [
        { "mode": "copy",
          "path": "/etc/airplanes/nope.conf",
          "from": "etc/airplanes/nope.conf",
          "owner": "root:root",
          "perm": "0644" }
    ]
}
JSON
    run airplanes_runtime_apply_managed_paths "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"source missing"* ]]
}
