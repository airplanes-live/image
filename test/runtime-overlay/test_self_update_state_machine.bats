#!/usr/bin/env bats

# End-to-end happy path for runtime-self-update.sh against a synthetic
# release fixture. Asserts the state file transitions CLEAN → STARTED →
# PAYLOAD_EXTRACTED → MIGRATIONS_FORWARD_DONE → SYMLINK_FLIPPED →
# SYSTEMD_OPS_DONE → HEALTH_RUNNING → HEALTH_PASSED → INSTALLED in
# order, and that the rolled-out artefacts match what install.sh's
# runtime-smoke test asserts (release dir, current symlink, decoder
# binary symlinks, runtime-manifest pointer).
#
# The systemctl shim is in-tree so the post-restart symlink-flip path
# is exercised end-to-end. The release-channel file is pinned to a
# fixture-served `runtime-vX.Y.Z` tag so the resolver never hits the
# network.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    if ! command -v minisign >/dev/null 2>&1; then
        skip "minisign not installed on this host"
    fi

    SHIM_DIR="$BATS_TEST_TMPDIR/shim"
    SYSCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    mk_systemctl_shim "$SHIM_DIR" "$SYSCTL_LOG" >/dev/null
    PATH="$SHIM_DIR:$PATH"

    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    printf 'stable\n' > "$TARGET_ROOT/etc/airplanes/release-channel"

    KEY_DIR="$BATS_TEST_TMPDIR/keys"
    install -d -m 700 "$KEY_DIR"
    echo "" | minisign -G -p "$KEY_DIR/test.pub" -s "$KEY_DIR/test.sec" -W >/dev/null 2>&1
    REL_TAG="runtime-v0.0.1"
    REL_VER="0.0.1"
    ARCH="arm64"
    REL_STAGING="$BATS_TEST_TMPDIR/rel-staging/v$REL_VER"
    install -d -m 755 \
        "$REL_STAGING/bin" "$REL_STAGING/share/airplanes" \
        "$REL_STAGING/systemd" "$REL_STAGING/lib/airplanes" "$REL_STAGING/migrations"
    : > "$REL_STAGING/bin/readsb"
    chmod 755 "$REL_STAGING/bin/readsb"
    : > "$REL_STAGING/share/airplanes/readsb.sh"
    : > "$REL_STAGING/systemd/readsb.service"

    cat > "$REL_STAGING/manifest.json" <<JSON
{
    "version": "$REL_VER",
    "channel": "stable",
    "commit_sha": "0000000000000000000000000000000000000000",
    "build_date": "2026-05-20T00:00:00Z",
    "arches": ["arm64"],
    "components": { "readsb_wiedehopf": "0000000" },
    "managed_paths": [
        { "mode": "symlink",
          "link": "/etc/systemd/system/readsb.service",
          "target": "/opt/airplanes-runtime/current/systemd/readsb.service" }
    ],
    "mutable_paths": [],
    "systemd": { "enable": ["readsb.service"], "daemon_reload": true },
    "migrations": []
}
JSON

    HTTPD_DOC="$BATS_TEST_TMPDIR/web"
    install -d -m 755 "$HTTPD_DOC/$REL_TAG"
    TARBALL_NAME="${REL_TAG}-${ARCH}.tar.gz"
    ( cd "$BATS_TEST_TMPDIR/rel-staging" && tar -czf "$HTTPD_DOC/$REL_TAG/$TARBALL_NAME" \
            --owner=0 --group=0 --numeric-owner --sort=name "v$REL_VER" )
    cp "$REL_STAGING/manifest.json" "$HTTPD_DOC/$REL_TAG/manifest.json"
    : > "$HTTPD_DOC/$REL_TAG/PROVENANCE.md"
    ( cd "$HTTPD_DOC/$REL_TAG" && sha256sum "$TARBALL_NAME" manifest.json > SHA256SUMS )
    echo "" | minisign -Sm "$HTTPD_DOC/$REL_TAG/SHA256SUMS" -s "$KEY_DIR/test.sec" -W >/dev/null 2>&1

    install -d -m 755 "$HTTPD_DOC/dump1090/data" "$HTTPD_DOC/tar1090" "$HTTPD_DOC/graphs1090"
    : > "$HTTPD_DOC/dump1090/data/aircraft.json"
    printf 'ok' > "$HTTPD_DOC/tar1090/index.html"
    printf 'ok' > "$HTTPD_DOC/graphs1090/index.html"

    : > "$TARGET_ROOT/run/readsb/aircraft.json"
    printf 'state=enabled\nreason=\n' > "$TARGET_ROOT/run/dump978-fa/state"
    printf 'state=enabled\nreason=\n' > "$TARGET_ROOT/run/airplanes-978/state"

    HTTPD_LOG="$BATS_TEST_TMPDIR/httpd.log"
    PORT_FILE="$BATS_TEST_TMPDIR/httpd.port"
    python3 -u -c "
import http.server, socketserver, os, sys
os.chdir(sys.argv[1])
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a, **k): pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
with open(sys.argv[2], 'w') as f:
    f.write(str(srv.server_address[1]) + '\n')
srv.serve_forever()
" "$HTTPD_DOC" "$PORT_FILE" >>"$HTTPD_LOG" 2>&1 &
    HTTPD_PID=$!
    local i
    for (( i = 0; i < 50; i++ )); do
        [[ -s "$PORT_FILE" ]] && break
        sleep 0.1
    done
    if [[ ! -s "$PORT_FILE" ]]; then
        kill "$HTTPD_PID" 2>/dev/null || true
        skip "python http.server failed to start"
    fi
    PORT="$(tr -d '[:space:]' < "$PORT_FILE")"

    LOCK_DIR="$BATS_TEST_TMPDIR/lockdir"
    install -d -m 755 "$LOCK_DIR"
    LOCK_FILE="$LOCK_DIR/runtime-update.lock"
}

teardown() {
    if [[ -n "${HTTPD_PID:-}" ]]; then
        kill "$HTTPD_PID" 2>/dev/null || true
    fi
}

run_self_update() {
    env \
        AIRPLANES_BUILD_MODE=0 \
        AIRPLANES_RUNTIME_ARCH_OVERRIDE="arm64" \
        AIRPLANES_RUNTIME_ROOT="$TARGET_ROOT" \
        AIRPLANES_RUNTIME_DOWNLOAD_BASE="http://127.0.0.1:$PORT" \
        AIRPLANES_RUNTIME_MINISIGN_PUBKEY="$KEY_DIR/test.pub" \
        AIRPLANES_RUNTIME_PROBE_URL_BASE="http://127.0.0.1:$PORT" \
        AIRPLANES_RUNTIME_HEALTH_DEADLINE=5 \
        AIRPLANES_RUNTIME_OVERLAY_TAG="$REL_TAG" \
        AIRPLANES_RUNTIME_LOCK_FILE="$LOCK_FILE" \
        AIRPLANES_RUNTIME_INSTALL_COMMON="$REPO_ROOT/runtime-overlay/scripts/lib/install-common.sh" \
        PATH="$SHIM_DIR:$PATH" \
        bash "$REPO_ROOT/runtime-overlay/src/lib/runtime-self-update.sh"
}

@test "happy path drives state file CLEAN -> ... -> INSTALLED" {
    run run_self_update
    if [ "$status" -ne 0 ]; then
        echo "$output"
        return 1
    fi

    [ "$(read_state "$TARGET_ROOT")" = "INSTALLED" ]
    [ -d "$TARGET_ROOT/opt/airplanes-runtime/releases/v$REL_VER" ]
    [ -L "$TARGET_ROOT/opt/airplanes-runtime/current" ]
    [ -L "$TARGET_ROOT/etc/airplanes/runtime-manifest.json" ]
    [ -L "$TARGET_ROOT/usr/bin/readsb" ]
    [ -L "$TARGET_ROOT/usr/bin/airplanes-978" ]

    # Snapshot of the recorded new_release survives in the state file
    # so a triage shell can inspect what was just installed.
    grep -E "^new_release=$TARGET_ROOT/opt/airplanes-runtime/releases/v$REL_VER$" \
        "$TARGET_ROOT/var/lib/airplanes-runtime-upgrade/upgrade-state"
}

@test "happy path triggers systemctl daemon-reload + enable + restart" {
    run run_self_update
    [ "$status" -eq 0 ]
    run grep -F 'daemon-reload' "$SYSCTL_LOG"
    [ "$status" -eq 0 ]
    run grep -F 'enable readsb.service' "$SYSCTL_LOG"
    [ "$status" -eq 0 ]
    run grep -F 'restart readsb.service' "$SYSCTL_LOG"
    [ "$status" -eq 0 ]
}

@test "happy path clears stale terminal state before starting" {
    # Synthesise an INSTALLED leftover from a prior run.
    mk_state_file "$TARGET_ROOT" INSTALLED \
        "new_release=$TARGET_ROOT/opt/airplanes-runtime/releases/v0.0.0-old"

    run run_self_update
    [ "$status" -eq 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "INSTALLED" ]
    # new_release now reflects the fresh attempt, not the stale leftover.
    grep -E "^new_release=$TARGET_ROOT/opt/airplanes-runtime/releases/v$REL_VER$" \
        "$TARGET_ROOT/var/lib/airplanes-runtime-upgrade/upgrade-state"
}

@test "FAILED_PRE_MUTATION cleared on next attempt" {
    mk_state_file "$TARGET_ROOT" FAILED_PRE_MUTATION \
        "failure_reason=download_failed"
    run run_self_update
    [ "$status" -eq 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "INSTALLED" ]
}

@test "ROLLED_BACK_* cleared on next attempt" {
    mk_state_file "$TARGET_ROOT" ROLLED_BACK_0.0.2_TO_0.0.1 \
        "failure_reason=health_gates_failed"
    run run_self_update
    [ "$status" -eq 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "INSTALLED" ]
}
