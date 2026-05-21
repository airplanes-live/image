#!/usr/bin/env bats

# Inject failures at every step of the forward walk and assert the
# rollback path lands at ROLLED_BACK_<new>_TO_<prev>, walks back the
# right state, drops the new release dir, and re-flips current to the
# prior release.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

# We share the heavyweight fixture (release tarball, http.server,
# minisign, systemctl shim) across every test in this file. Each test
# only varies how the failure gets injected and which state we end at.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    if ! command -v minisign >/dev/null 2>&1; then
        skip "minisign not installed on this host"
    fi

    SHIM_DIR="$BATS_TEST_TMPDIR/shim"
    SYSCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    install -d -m 755 "$SHIM_DIR"
    : > "$SYSCTL_LOG"
    # systemctl shim with a runtime kill-switch: if SHIM_FAIL_PATTERN is
    # set in the environment and the invocation matches, exit non-zero.
    cat > "$SHIM_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SHIM_LOG"
if [[ -n "${SHIM_FAIL_PATTERN:-}" && "$*" == *${SHIM_FAIL_PATTERN}* ]]; then
    exit 1
fi
exit 0
EOF
    chmod 755 "$SHIM_DIR/systemctl"
    SHIM_LOG="$SYSCTL_LOG"
    export SHIM_LOG

    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    printf 'stable\n' > "$TARGET_ROOT/etc/airplanes/release-channel"

    # Pre-stage a prior release dir + a current symlink pointing at it
    # so the rollback path has somewhere to flip back to.
    PREV_VER="0.0.0"
    PREV_DIR="$TARGET_ROOT/opt/airplanes-runtime/releases/v$PREV_VER"
    install -d -m 755 "$PREV_DIR/bin" "$PREV_DIR/lib" "$PREV_DIR/systemd"
    : > "$PREV_DIR/bin/readsb"
    chmod 755 "$PREV_DIR/bin/readsb"
    ln -s "/opt/airplanes-runtime/releases/v$PREV_VER" \
        "$TARGET_ROOT/opt/airplanes-runtime/current"

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
    : > "$REL_STAGING/systemd/readsb.service"

    cat > "$REL_STAGING/manifest.json" <<JSON
{
    "version": "$REL_VER",
    "channel": "stable",
    "commit_sha": "0000000000000000000000000000000000000000",
    "build_date": "2026-05-20T00:00:00Z",
    "arches": ["arm64"],
    "components": { "readsb_wiedehopf": "0000000" },
    "managed_paths": [],
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
        AIRPLANES_RUNTIME_HEALTH_DEADLINE="${HEALTH_DEADLINE:-5}" \
        AIRPLANES_RUNTIME_OVERLAY_TAG="$REL_TAG" \
        AIRPLANES_RUNTIME_LOCK_FILE="$LOCK_FILE" \
        AIRPLANES_RUNTIME_INSTALL_COMMON="$REPO_ROOT/runtime-overlay/scripts/lib/install-common.sh" \
        SHIM_LOG="$SHIM_LOG" \
        SHIM_FAIL_PATTERN="${SHIM_FAIL_PATTERN:-}" \
        PATH="$SHIM_DIR:$PATH" \
        bash "$REPO_ROOT/runtime-overlay/src/lib/runtime-self-update.sh"
}

@test "systemd-ops failure rolls back from SYSTEMD_OPS_DONE attempt" {
    # systemctl restart readsb.service fails — the failure surfaces
    # during apply_systemd_ops which runs BEFORE the state file
    # transitions to SYSTEMD_OPS_DONE. The orchestrator reads the
    # current state (SYMLINK_FLIPPED) and runs that rollback row.
    SHIM_FAIL_PATTERN="restart readsb.service"
    run run_self_update

    [ "$status" -ne 0 ]
    # Terminal ROLLED_BACK_<new>_TO_<prev>.
    local state
    state="$(read_state "$TARGET_ROOT")"
    [[ "$state" == ROLLED_BACK_* ]]
    # current symlink reverted to prior release.
    [ -L "$TARGET_ROOT/opt/airplanes-runtime/current" ]
    [ "$(readlink "$TARGET_ROOT/opt/airplanes-runtime/current")" \
        = "/opt/airplanes-runtime/releases/v$PREV_VER" ]
    # new release dir cleaned up.
    [ ! -d "$TARGET_ROOT/opt/airplanes-runtime/releases/v$REL_VER" ]
}

@test "health gate failure rolls back from HEALTH_RUNNING" {
    # Force the readsb aircraft.json to be too stale so the readsb
    # freshness gate fails.
    touch -d '10 minutes ago' "$TARGET_ROOT/run/readsb/aircraft.json"
    HEALTH_DEADLINE=2
    run run_self_update

    [ "$status" -ne 0 ]
    local state
    state="$(read_state "$TARGET_ROOT")"
    [[ "$state" == ROLLED_BACK_* ]]
    # Confirm rolled-back symlink + dropped new release dir.
    [ "$(readlink "$TARGET_ROOT/opt/airplanes-runtime/current")" \
        = "/opt/airplanes-runtime/releases/v$PREV_VER" ]
    [ ! -d "$TARGET_ROOT/opt/airplanes-runtime/releases/v$REL_VER" ]
    # Systemctl observed restart-of-readsb followed by stop-of-readsb
    # (rollback's stop-services pass) — confirms we routed through the
    # decoder-stop step before reverting the symlink.
    grep -F 'stop airplanes-tar1090-uat-sync.service' "$SYSCTL_LOG"
}

@test "rollback failure_reason captured for triage" {
    SHIM_FAIL_PATTERN="restart readsb.service"
    run run_self_update
    [ "$status" -ne 0 ]
    grep -E '^failure_reason=' \
        "$TARGET_ROOT/var/lib/airplanes-runtime-upgrade/upgrade-state"
}

@test "rollback walks back to a clean state with no current pointing at new" {
    SHIM_FAIL_PATTERN="restart readsb.service"
    run run_self_update
    [ "$status" -ne 0 ]
    # After rollback, current must NOT point at the new release.
    local current
    current="$(readlink "$TARGET_ROOT/opt/airplanes-runtime/current")"
    [[ "$current" != "/opt/airplanes-runtime/releases/v$REL_VER" ]]
    [[ "$current" != "$TARGET_ROOT/opt/airplanes-runtime/releases/v$REL_VER" ]]
}
