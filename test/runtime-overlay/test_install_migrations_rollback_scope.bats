#!/usr/bin/env bats

# Verifies that airplanes_runtime_run_migrations_rollback ONLY undoes
# migrations completed during the current install attempt, not migrations
# previously recorded in the cross-install applied file.
#
# This matters because `run_when: first_install_of_version` records the
# migration on first successful install. A later install attempt that
# fails partway through must not roll back THAT earlier first-install
# migration during the failed attempt's rollback — only the migrations
# this attempt actually completed.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    RELEASE_DIR="$(mk_release_dir "$BATS_TEST_TMPDIR")"
}

@test "rollback only touches migrations recorded in this attempt" {
    install -d -m 755 "$TARGET_ROOT/etc/default" "$TARGET_ROOT/etc/airplanes"
    # Simulate a prior successful first_install_of_version migration that
    # left the cross-install applied file populated.
    printf 'old-migration\n' > "$TARGET_ROOT/etc/airplanes/runtime-migrations.applied"
    printf 'OLD=existing\n' > "$TARGET_ROOT/etc/default/test-old"

    # Now run a new attempt with two migrations: a config_kv (which will
    # complete forward), then a shell that fails. The shell failure
    # short-circuits the forward run; rollback should ONLY undo the
    # config_kv (the only one this attempt completed) — NOT the prior
    # "old-migration" recorded in the cross-install file.
    cat > "$RELEASE_DIR/migrations/fail.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    chmod 755 "$RELEASE_DIR/migrations/fail.sh"
    cat > "$RELEASE_DIR/migrations/fail.rollback.sh" <<'SH'
#!/usr/bin/env bash
touch "${AIRPLANES_RUNTIME_TARGET_ROOT}/var/lib/should-not-run"
SH
    chmod 755 "$RELEASE_DIR/migrations/fail.rollback.sh"
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "2.0.0", "channel": "stable",
    "mutable_paths": ["/etc/default/test-old"],
    "migrations": [
        { "id": "this-attempt", "type": "config_kv",
          "file": "/etc/default/test-old",
          "set": { "OLD": "new-value" } },
        { "id": "fail-migration", "type": "shell",
          "script": "migrations/fail.sh",
          "rollback_script": "migrations/fail.rollback.sh" }
    ]
}
JSON

    # Forward fails on the second migration.
    run airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -ne 0 ]

    # Confirm: cross-install applied file now contains BOTH old-migration
    # and this-attempt; the per-attempt file only has this-attempt.
    run grep -F 'old-migration'  "$TARGET_ROOT/etc/airplanes/runtime-migrations.applied"
    [ "$status" -eq 0 ]
    run grep -F 'this-attempt'   "$TARGET_ROOT/etc/airplanes/runtime-migrations.applied"
    [ "$status" -eq 0 ]
    run grep -F 'this-attempt' "$RELEASE_DIR/.attempt-migrations.applied"
    [ "$status" -eq 0 ]
    run grep -F 'old-migration' "$RELEASE_DIR/.attempt-migrations.applied"
    [ "$status" -ne 0 ]

    # Rollback the failed attempt.
    run airplanes_runtime_run_migrations_rollback "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]

    # File rolled back to its pre-this-attempt state.
    run grep -E '^OLD=existing$' "$TARGET_ROOT/etc/default/test-old"
    [ "$status" -eq 0 ]

    # The fail-migration rollback script must NOT have run (it wasn't
    # recorded as completed forward).
    [ ! -f "$TARGET_ROOT/var/lib/should-not-run" ]

    # old-migration is STILL recorded in the cross-install applied file —
    # rollback did not touch it.
    run grep -F 'old-migration' "$TARGET_ROOT/etc/airplanes/runtime-migrations.applied"
    [ "$status" -eq 0 ]
    # this-attempt was removed from both files.
    run grep -F 'this-attempt' "$TARGET_ROOT/etc/airplanes/runtime-migrations.applied"
    [ "$status" -ne 0 ]
}
