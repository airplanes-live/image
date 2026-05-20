#!/usr/bin/env bats

# Tests for runtime-overlay/scripts/gates/*.sh — release gates that the
# runtime-release.yml workflow runs against a built release tree. Each test
# synthesises the smallest release tree shape the gate looks at, deliberately
# injects the failure mode, and asserts the gate rejects it.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    GATES_DIR="$REPO_ROOT/runtime-overlay/scripts/gates"
    SYSTEMD_VERIFY="$GATES_DIR/systemd-verify.sh"
    LIGHTTPD_VERIFY="$GATES_DIR/lighttpd-verify.sh"
    MIGRATION_PAIR_CHECK="$GATES_DIR/migration-pair-check.sh"

    [ -x "$SYSTEMD_VERIFY" ]       || skip "systemd-verify.sh not executable"
    [ -x "$LIGHTTPD_VERIFY" ]      || skip "lighttpd-verify.sh not executable"
    [ -x "$MIGRATION_PAIR_CHECK" ] || skip "migration-pair-check.sh not executable"

    RELEASE_DIR="$BATS_TEST_TMPDIR/release"
    mkdir -p "$RELEASE_DIR"
}

# -- systemd-verify --------------------------------------------------------

@test "systemd-verify: rejects unit with malformed section header" {
    command -v systemd-analyze >/dev/null 2>&1 || skip "systemd-analyze not installed"

    mkdir -p "$RELEASE_DIR/systemd"
    cat > "$RELEASE_DIR/systemd/broken.service" <<'UNIT'
[Unit
Description=intentionally broken — section header missing closing bracket
[Service]
Type=oneshot
ExecStart=/bin/true
UNIT

    run "$SYSTEMD_VERIFY" --release-dir "$RELEASE_DIR"
    [ "$status" -ne 0 ]
}

@test "systemd-verify: accepts well-formed oneshot unit" {
    command -v systemd-analyze >/dev/null 2>&1 || skip "systemd-analyze not installed"

    mkdir -p "$RELEASE_DIR/systemd"
    cat > "$RELEASE_DIR/systemd/good.service" <<'UNIT'
[Unit]
Description=well-formed oneshot
[Service]
Type=oneshot
ExecStart=/usr/local/bin/synthetic-stub
[Install]
WantedBy=multi-user.target
UNIT

    run "$SYSTEMD_VERIFY" --release-dir "$RELEASE_DIR"
    [ "$status" -eq 0 ]
}

# -- lighttpd-verify -------------------------------------------------------

@test "lighttpd-verify: rejects syntactically-broken conf snippet" {
    command -v lighttpd >/dev/null 2>&1 || skip "lighttpd not installed"

    mkdir -p "$RELEASE_DIR/etc/lighttpd/conf-available"
    # Unbalanced quote: lighttpd's parser refuses to load this.
    printf 'server.tag = "no-closing-quote\n' \
        > "$RELEASE_DIR/etc/lighttpd/conf-available/broken.conf"

    run "$LIGHTTPD_VERIFY" --release-dir "$RELEASE_DIR"
    [ "$status" -ne 0 ]
}

@test "lighttpd-verify: accepts trivial well-formed snippet" {
    command -v lighttpd >/dev/null 2>&1 || skip "lighttpd not installed"

    mkdir -p "$RELEASE_DIR/etc/lighttpd/conf-available"
    # `server.tag = "x"` is a directive lighttpd always understands without
    # loading any module.
    printf 'server.tag = "synthetic-ok"\n' \
        > "$RELEASE_DIR/etc/lighttpd/conf-available/ok.conf"

    run "$LIGHTTPD_VERIFY" --release-dir "$RELEASE_DIR"
    [ "$status" -eq 0 ]
}

@test "lighttpd-verify: tolerates missing conf-available dir" {
    command -v lighttpd >/dev/null 2>&1 || skip "lighttpd not installed"

    # No etc/lighttpd in the release tree — gate is a no-op, returns 0.
    run "$LIGHTTPD_VERIFY" --release-dir "$RELEASE_DIR"
    [ "$status" -eq 0 ]
}

# -- migration-pair-check --------------------------------------------------

# All migration-pair-check cases set AIRPLANES_MIGRATION_PAIR_SKIP_REMOTE=1
# so the gate's gh-driven cross-release id-uniqueness lookup is skipped in
# tests. The remote path is exercised in CI against a live repo.

@test "migration-pair-check: rejects shell migration missing rollback_script" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"

    cat > "$RELEASE_DIR/manifest.json" <<'MANIFEST'
{
  "version": "0.0.0",
  "channel": "dev",
  "commit_sha": "0000000000000000000000000000000000000000",
  "build_date": "2026-05-20T00:00:00Z",
  "arches": ["arm64"],
  "components": {"readsb_wiedehopf": "abc1234"},
  "managed_paths": [],
  "mutable_paths": [],
  "systemd": {"enable": [], "disable": [], "daemon_reload": true},
  "migrations": [
    {
      "id": "missing-rollback",
      "type": "shell",
      "script": "migrations/forward.sh"
    }
  ]
}
MANIFEST

    AIRPLANES_MIGRATION_PAIR_SKIP_REMOTE=1 \
        run "$MIGRATION_PAIR_CHECK" --release-dir "$RELEASE_DIR" --channel dev
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing 'rollback_script'"* ]]
}

@test "migration-pair-check: rejects shell migration whose script file is missing" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"

    cat > "$RELEASE_DIR/manifest.json" <<'MANIFEST'
{
  "version": "0.0.0",
  "channel": "dev",
  "commit_sha": "0000000000000000000000000000000000000000",
  "build_date": "2026-05-20T00:00:00Z",
  "arches": ["arm64"],
  "components": {"readsb_wiedehopf": "abc1234"},
  "managed_paths": [],
  "mutable_paths": [],
  "systemd": {"enable": [], "disable": [], "daemon_reload": true},
  "migrations": [
    {
      "id": "missing-file",
      "type": "shell",
      "script": "migrations/forward.sh",
      "rollback_script": "migrations/rollback.sh"
    }
  ]
}
MANIFEST
    # Note: no migrations/ dir created, so script + rollback_script both
    # resolve to missing files.

    AIRPLANES_MIGRATION_PAIR_SKIP_REMOTE=1 \
        run "$MIGRATION_PAIR_CHECK" --release-dir "$RELEASE_DIR" --channel dev
    [ "$status" -ne 0 ]
    [[ "$output" == *"script missing"* || "$output" == *"rollback_script missing"* ]]
}

@test "migration-pair-check: rejects duplicate migration ids within release" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"

    cat > "$RELEASE_DIR/manifest.json" <<'MANIFEST'
{
  "version": "0.0.0",
  "channel": "dev",
  "commit_sha": "0000000000000000000000000000000000000000",
  "build_date": "2026-05-20T00:00:00Z",
  "arches": ["arm64"],
  "components": {"readsb_wiedehopf": "abc1234"},
  "managed_paths": [],
  "mutable_paths": [],
  "systemd": {"enable": [], "disable": [], "daemon_reload": true},
  "migrations": [
    {"id": "same-id", "type": "udev_reload"},
    {"id": "same-id", "type": "sysctl_reload"}
  ]
}
MANIFEST

    AIRPLANES_MIGRATION_PAIR_SKIP_REMOTE=1 \
        run "$MIGRATION_PAIR_CHECK" --release-dir "$RELEASE_DIR" --channel dev
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate migration ids"* ]]
}

@test "migration-pair-check: accepts manifest with paired shell migration" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"

    mkdir -p "$RELEASE_DIR/migrations"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$RELEASE_DIR/migrations/forward.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$RELEASE_DIR/migrations/rollback.sh"
    chmod 0755 "$RELEASE_DIR/migrations/forward.sh" \
               "$RELEASE_DIR/migrations/rollback.sh"

    cat > "$RELEASE_DIR/manifest.json" <<'MANIFEST'
{
  "version": "0.0.0",
  "channel": "dev",
  "commit_sha": "0000000000000000000000000000000000000000",
  "build_date": "2026-05-20T00:00:00Z",
  "arches": ["arm64"],
  "components": {"readsb_wiedehopf": "abc1234"},
  "managed_paths": [],
  "mutable_paths": [],
  "systemd": {"enable": [], "disable": [], "daemon_reload": true},
  "migrations": [
    {
      "id": "paired-shell",
      "type": "shell",
      "script": "migrations/forward.sh",
      "rollback_script": "migrations/rollback.sh"
    }
  ]
}
MANIFEST

    AIRPLANES_MIGRATION_PAIR_SKIP_REMOTE=1 \
        run "$MIGRATION_PAIR_CHECK" --release-dir "$RELEASE_DIR" --channel dev
    [ "$status" -eq 0 ]
}
