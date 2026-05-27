#!/usr/bin/env bats

# Confirm the upgrade flock is held for the entire orchestrator lifetime,
# not released mid-protocol. A second invocation launched while the first
# is running must exit 75 (lock contention) regardless of where the first
# has progressed to.

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

    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    printf 'stable\n' > "$TARGET_ROOT/etc/airplanes/release-channel"

    KEY_DIR="$BATS_TEST_TMPDIR/keys"
    install -d -m 700 "$KEY_DIR"
    echo "" | minisign -G -p "$KEY_DIR/test.pub" -s "$KEY_DIR/test.sec" -W >/dev/null 2>&1

    REL_TAG="v0.0.1"
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
    stage_product_runtime_assets "$REL_STAGING" "$HTTPD_DOC/$REL_TAG" "$ARCH" "$KEY_DIR/test.sec"

    install -d -m 755 "$HTTPD_DOC/tar1090/data" "$HTTPD_DOC/tar1090" "$HTTPD_DOC/graphs1090"
    : > "$HTTPD_DOC/tar1090/data/aircraft.json"
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

@test "second invocation while first is running exits 75" {
    # Launch the first orchestrator in the background, capturing stdout
    # so we can wait for it to log progress (the lock is acquired before
    # the first message is printed).
    OUT1="$BATS_TEST_TMPDIR/run1.out"
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
        bash "$REPO_ROOT/runtime-overlay/src/lib/runtime-self-update.sh" >"$OUT1" 2>&1 &
    PID1=$!

    # Wait for the first to log its initial line (signal that the lock
    # was acquired and the state machine has started).
    local i
    for (( i = 0; i < 100; i++ )); do
        if grep -q "runtime-self-update:" "$OUT1" 2>/dev/null; then
            break
        fi
        sleep 0.05
    done

    # Run the second invocation while the first is still in flight.
    run env \
        AIRPLANES_BUILD_MODE=0 \
        AIRPLANES_RUNTIME_ARCH_OVERRIDE="arm64" \
        AIRPLANES_RUNTIME_ROOT="$TARGET_ROOT" \
        AIRPLANES_RUNTIME_DOWNLOAD_BASE="http://127.0.0.1:$PORT" \
        AIRPLANES_RUNTIME_MINISIGN_PUBKEY="$KEY_DIR/test.pub" \
        AIRPLANES_RUNTIME_PROBE_URL_BASE="http://127.0.0.1:$PORT" \
        AIRPLANES_RUNTIME_OVERLAY_TAG="$REL_TAG" \
        AIRPLANES_RUNTIME_LOCK_FILE="$LOCK_FILE" \
        AIRPLANES_RUNTIME_INSTALL_COMMON="$REPO_ROOT/runtime-overlay/scripts/lib/install-common.sh" \
        PATH="$SHIM_DIR:$PATH" \
        bash "$REPO_ROOT/runtime-overlay/src/lib/runtime-self-update.sh"

    [ "$status" -eq 75 ]

    # Wait for the first to finish so cleanup is deterministic.
    wait "$PID1" || true
}
