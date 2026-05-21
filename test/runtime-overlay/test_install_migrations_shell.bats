#!/usr/bin/env bats

# Tests shell-type migrations.
# - forward script runs and observes RELEASE_DIR + AIRPLANES_RUNTIME_TARGET_ROOT envs
# - rollback script also runs with the same envs
# - rollback is invoked from the NEW release dir's absolute path (decision in plan)

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    RELEASE_DIR="$(mk_release_dir "$BATS_TEST_TMPDIR")"
    # Stage a forward + rollback script pair under migrations/.
    cat > "$RELEASE_DIR/migrations/touch-forward.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Drop a marker the test can check for; capture envs into it.
mkdir -p "${AIRPLANES_RUNTIME_TARGET_ROOT}/var/lib/test-marker"
{
    printf 'forward\n'
    printf 'RELEASE_DIR=%s\n' "${RELEASE_DIR}"
    printf 'AIRPLANES_RUNTIME_TARGET_ROOT=%s\n' "${AIRPLANES_RUNTIME_TARGET_ROOT}"
} > "${AIRPLANES_RUNTIME_TARGET_ROOT}/var/lib/test-marker/forward"
SH
    chmod 755 "$RELEASE_DIR/migrations/touch-forward.sh"

    cat > "$RELEASE_DIR/migrations/touch-rollback.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${AIRPLANES_RUNTIME_TARGET_ROOT}/var/lib/test-marker"
{
    printf 'rollback\n'
    printf 'RELEASE_DIR=%s\n' "${RELEASE_DIR}"
} > "${AIRPLANES_RUNTIME_TARGET_ROOT}/var/lib/test-marker/rollback"
SH
    chmod 755 "$RELEASE_DIR/migrations/touch-rollback.sh"
}

@test "forward script executes with RELEASE_DIR + TARGET_ROOT env" {
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<JSON
{
    "version": "1.0.0", "channel": "stable",
    "mutable_paths": [],
    "migrations": [
        { "id": "test-shell", "type": "shell",
          "script": "migrations/touch-forward.sh",
          "rollback_script": "migrations/touch-rollback.sh" }
    ]
}
JSON
    run airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ -f "$TARGET_ROOT/var/lib/test-marker/forward" ]
    run grep -F "RELEASE_DIR=$RELEASE_DIR" "$TARGET_ROOT/var/lib/test-marker/forward"
    [ "$status" -eq 0 ]
}

@test "rollback script runs from the NEW release dir even after a flip" {
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<JSON
{
    "version": "1.0.0", "channel": "stable",
    "mutable_paths": [],
    "migrations": [
        { "id": "test-shell", "type": "shell",
          "script": "migrations/touch-forward.sh",
          "rollback_script": "migrations/touch-rollback.sh" }
    ]
}
JSON
    airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    # Simulate a flip having occurred: point current at a different dir, but
    # still pass the original RELEASE_DIR to the rollback. The rollback
    # should resolve scripts from RELEASE_DIR (the new release), not from
    # /opt/airplanes-runtime/current/.
    install -d -m 755 "$TARGET_ROOT/opt/airplanes-runtime"
    rm -f "$TARGET_ROOT/opt/airplanes-runtime/current"
    ln -s "$BATS_TEST_TMPDIR/somewhere-else" "$TARGET_ROOT/opt/airplanes-runtime/current"

    run airplanes_runtime_run_migrations_rollback "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ -f "$TARGET_ROOT/var/lib/test-marker/rollback" ]
    run grep -F "RELEASE_DIR=$RELEASE_DIR" "$TARGET_ROOT/var/lib/test-marker/rollback"
    [ "$status" -eq 0 ]
}

@test "missing forward script is a hard error" {
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "mutable_paths": [],
    "migrations": [
        { "id": "test-shell", "type": "shell",
          "script": "migrations/does-not-exist.sh",
          "rollback_script": "migrations/touch-rollback.sh" }
    ]
}
JSON
    run airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
}

@test "rollback skips migrations that did not complete forward" {
    # Forward migration intentionally fails so the rollback should be a no-op
    # for it.
    cat > "$RELEASE_DIR/migrations/will-fail.sh" <<'SH'
#!/usr/bin/env bash
exit 7
SH
    chmod 755 "$RELEASE_DIR/migrations/will-fail.sh"
    cat > "$RELEASE_DIR/migrations/never-runs.rollback.sh" <<'SH'
#!/usr/bin/env bash
touch "${AIRPLANES_RUNTIME_TARGET_ROOT}/var/lib/test-marker/wrongly-rolled-back"
SH
    chmod 755 "$RELEASE_DIR/migrations/never-runs.rollback.sh"

    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{
    "version": "1.0.0", "channel": "stable",
    "mutable_paths": [],
    "migrations": [
        { "id": "fail-migration", "type": "shell",
          "script": "migrations/will-fail.sh",
          "rollback_script": "migrations/never-runs.rollback.sh" }
    ]
}
JSON
    run airplanes_runtime_run_migrations_forward "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -ne 0 ]

    # Now run rollback. Because the migration never recorded forward
    # completion, the rollback should NOT execute the rollback script.
    run airplanes_runtime_run_migrations_rollback "$BATS_TEST_TMPDIR/manifest.json" "$RELEASE_DIR" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ ! -f "$TARGET_ROOT/var/lib/test-marker/wrongly-rolled-back" ]
}
