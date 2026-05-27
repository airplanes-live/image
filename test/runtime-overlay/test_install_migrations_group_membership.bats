#!/usr/bin/env bats

# Tests group_membership migrations.
# - idempotent: re-running adds nothing
# - missing group is a hard error
# - relies on shimmed getent/adduser so the test machine isn't mutated

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    SHIM_DIR="$BATS_TEST_TMPDIR/shimdir"
    SHIM_LOG="$BATS_TEST_TMPDIR/shim.log"
    install -d -m 755 "$SHIM_DIR"
    : > "$SHIM_LOG"
    # State for the fake getent: a colon-separated line per group.
    GROUPS_FILE="$BATS_TEST_TMPDIR/groups"
    : > "$GROUPS_FILE"

    cat > "$SHIM_DIR/getent" <<EOF
#!/usr/bin/env bash
# shim: only supports 'getent group <name>' against a static file.
if [[ "\$1" != "group" || -z "\${2:-}" ]]; then
    exit 2
fi
line=\$(grep "^\$2:" "$GROUPS_FILE" || true)
if [[ -z "\$line" ]]; then
    exit 2
fi
printf '%s\\n' "\$line"
EOF
    chmod 755 "$SHIM_DIR/getent"

    cat > "$SHIM_DIR/adduser" <<EOF
#!/usr/bin/env bash
# shim: only supports 'adduser <user> <group>'. Appends user to the group's
# fourth field in the static file.
printf 'adduser %s %s\\n' "\$1" "\$2" >> "$SHIM_LOG"
user="\$1"; group="\$2"
line=\$(grep "^\$group:" "$GROUPS_FILE" || true)
if [[ -z "\$line" ]]; then
    exit 1
fi
# Split on ":" and append user to field 4 (members).
IFS=':' read -r name passwd gid members <<<"\$line"
if [[ -n "\$members" ]]; then
    members="\$members,\$user"
else
    members="\$user"
fi
# Replace the line in-place.
new="\$name:\$passwd:\$gid:\$members"
tmp=\$(mktemp "$GROUPS_FILE.XXXXXX")
grep -v "^\$group:" "$GROUPS_FILE" > "\$tmp" || true
printf '%s\\n' "\$new" >> "\$tmp"
mv -f "\$tmp" "$GROUPS_FILE"
EOF
    chmod 755 "$SHIM_DIR/adduser"

    PATH="$SHIM_DIR:$PATH"

    source_install_lib

    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    RELEASE_DIR="$(mk_release_dir "$BATS_TEST_TMPDIR")"

    # Pre-seed groups: plugdev and dialout exist; readsb is NOT yet a member.
    printf 'plugdev:x:46:\n' >> "$GROUPS_FILE"
    printf 'dialout:x:20:\n' >> "$GROUPS_FILE"
}

@test "first run adds the user to both groups" {
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "mutable_paths": [],
    "migrations": [
        { "id": "readsb-groups", "type": "group_membership",
          "user": "readsb", "groups": ["plugdev", "dialout"] }
    ]
}
JSON
    run airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    run grep -c '^adduser readsb' "$SHIM_LOG"
    [ "$output" = "2" ]
    # The applied-record now lists the migration id.
    run grep -Fxq 'readsb-groups' "$TARGET_ROOT/etc/airplanes/runtime-migrations.applied"
    [ "$status" -eq 0 ]
}

@test "second run with user already in groups is a no-op (no extra adduser calls)" {
    # Seed memberships directly.
    sed -i 's/^plugdev:.*/plugdev:x:46:readsb/' "$GROUPS_FILE"
    sed -i 's/^dialout:.*/dialout:x:20:readsb/' "$GROUPS_FILE"
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "mutable_paths": [],
    "migrations": [
        { "id": "readsb-groups", "type": "group_membership",
          "user": "readsb", "groups": ["plugdev", "dialout"] }
    ]
}
JSON
    run airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    run grep -c '^adduser ' "$SHIM_LOG"
    [ "$output" = "0" ]
}

@test "missing group is a hard error" {
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "mutable_paths": [],
    "migrations": [
        { "id": "readsb-groups", "type": "group_membership",
          "user": "readsb", "groups": ["doesnotexist"] }
    ]
}
JSON
    run airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"doesnotexist"* ]]
}

@test "membership match uses fixed-string compare (readsbx must not satisfy readsb)" {
    # plugdev already has readsbx; readsb is NOT a member. The naive grep
    # would match the substring and skip adduser, leaving the readsb user
    # silently un-added. The fixed-string member walk should detect the
    # mismatch and call adduser readsb plugdev.
    sed -i 's/^plugdev:.*/plugdev:x:46:readsbx/' "$GROUPS_FILE"
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "mutable_paths": [],
    "migrations": [
        { "id": "readsb-groups", "type": "group_membership",
          "user": "readsb", "groups": ["plugdev"] }
    ]
}
JSON
    run airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    run grep -F 'adduser readsb plugdev' "$SHIM_LOG"
    [ "$status" -eq 0 ]
}
