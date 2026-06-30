#!/usr/bin/env bats

# End-to-end runtime-mode test against a synthetic root.
# Stubs out systemctl + the health-gate probes (via a tmpdir http.server
# fixture + pre-staged state files) so the test exercises the runtime
# install path without touching the host. Asserts the directory layout
# post-install matches expectations.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    if ! command -v minisign >/dev/null 2>&1; then
        skip "minisign not installed on this host"
    fi

    # systemctl shim so the runtime path's systemd ops are no-ops the test
    # can inspect. The shared shim also answers `show … --value` with healthy
    # defaults so the unit-health gate in run_health_gates passes.
    SHIM_DIR="$BATS_TEST_TMPDIR/shim"
    SYSCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
    mk_systemctl_shim "$SHIM_DIR" "$SYSCTL_LOG" >/dev/null
    PATH="$SHIM_DIR:$PATH"

    # Synthetic root.
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    install -d -m 755 "$TARGET_ROOT/etc/airplanes"
    # Pre-stage release-channel pointing at dev so the resolver doesn't
    # hit the network for a stable tag list.
    printf 'stable\n' > "$TARGET_ROOT/etc/airplanes/release-channel"

    # Minisign key + release fixture (matching the build-mode test shape).
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
          "target": "/opt/airplanes/current/systemd/readsb.service" }
    ],
    "mutable_paths": [],
    "systemd": { "enable": ["readsb.service"], "daemon_reload": true },
    "migrations": []
}
JSON

    HTTPD_DOC="$BATS_TEST_TMPDIR/web"
    install -d -m 755 "$HTTPD_DOC/$REL_TAG"
    stage_product_runtime_assets "$REL_STAGING" "$HTTPD_DOC/$REL_TAG" "$ARCH" "$KEY_DIR/test.sec"

    # Also serve the three HTTP-probe responses so the health gates pass.
    install -d -m 755 "$HTTPD_DOC/tar1090/data" "$HTTPD_DOC/tar1090" "$HTTPD_DOC/graphs1090"
    : > "$HTTPD_DOC/tar1090/data/aircraft.json"
    printf 'ok' > "$HTTPD_DOC/tar1090/index.html"
    printf 'ok' > "$HTTPD_DOC/graphs1090/index.html"

    # Pre-stage the on-device gate inputs:
    : > "$TARGET_ROOT/run/readsb/aircraft.json"
    printf 'state=enabled\nreason=ok\n' > "$TARGET_ROOT/run/airplanes/dump978-fa/state"
    printf 'state=enabled\nreason=ok\n' > "$TARGET_ROOT/run/airplanes/978/state"

    # Spawn http.server.
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
}

teardown() {
    if [[ -n "${HTTPD_PID:-}" ]]; then
        kill "$HTTPD_PID" 2>/dev/null || true
    fi
}

# Helper: invoke install.sh in runtime mode against the fixture. The
# pinned channel side-steps the git-ls-remote dependency of the stable/dev
# resolvers — we set AIRPLANES_RUNTIME_OVERLAY_TAG and the lib's "pinned"
# branch returns it.
run_install_runtime() {
    env \
        AIRPLANES_BUILD_MODE=0 \
        AIRPLANES_RUNTIME_ARCH_OVERRIDE="arm64" \
        AIRPLANES_RUNTIME_ROOT="$TARGET_ROOT" \
        AIRPLANES_RUNTIME_DOWNLOAD_BASE="http://127.0.0.1:$PORT" \
        AIRPLANES_RUNTIME_MINISIGN_PUBKEY="$KEY_DIR/test.pub" \
        AIRPLANES_RUNTIME_PROBE_URL_BASE="http://127.0.0.1:$PORT" \
        AIRPLANES_RUNTIME_HEALTH_DEADLINE=5 \
        AIRPLANES_RUNTIME_UNIT_WINDOW_CUSHION=0 \
        AIRPLANES_RUNTIME_OVERLAY_TAG="$REL_TAG" \
        PATH="$SHIM_DIR:$PATH" \
        bash "$REPO_ROOT/runtime-overlay/install.sh" --runtime
}

@test "runtime install lays release dir, flips current, applies managed paths" {
    run run_install_runtime
    if [ "$status" -ne 0 ]; then
        echo "$output"
        return 1
    fi
    [ -d "$TARGET_ROOT/opt/airplanes/releases/v$REL_VER" ]
    [ -L "$TARGET_ROOT/opt/airplanes/current" ]
    # In runtime mode the link target is the absolute release-dir path
    # the install pipeline operated against. In production that's
    # /opt/airplanes/releases/v<X>/; in tests TARGET_ROOT is a
    # tmpdir so the link string contains the rebase.
    [ "$(readlink "$TARGET_ROOT/opt/airplanes/current")" = "$TARGET_ROOT/opt/airplanes/releases/v$REL_VER" ]
    [ -L "$TARGET_ROOT/etc/systemd/system/readsb.service" ]
    [ -L "$TARGET_ROOT/usr/local/bin/readsb" ]
    [ -L "$TARGET_ROOT/usr/local/bin/dump978-fa" ]
    [ ! -e "$TARGET_ROOT/usr/bin/readsb" ]
    # systemd ops shimmed: daemon-reload + enable + restart all logged.
    run grep -F 'daemon-reload' "$SYSCTL_LOG"
    [ "$status" -eq 0 ]
    run grep -F 'enable readsb.service' "$SYSCTL_LOG"
    [ "$status" -eq 0 ]
    run grep -F 'restart readsb.service' "$SYSCTL_LOG"
    [ "$status" -eq 0 ]
    # Runtime-manifest pointer was recorded.
    [ -L "$TARGET_ROOT/etc/airplanes/runtime-manifest.json" ]
    [ "$(readlink "$TARGET_ROOT/etc/airplanes/runtime-manifest.json")" = "/opt/airplanes/current/manifest.json" ]
}

@test "runtime install fails closed when health gate trips" {
    # Move the aircraft.json into staleness so the readsb gate fails.
    touch -d '10 minutes ago' "$TARGET_ROOT/run/readsb/aircraft.json"
    run run_install_runtime
    [ "$status" -ne 0 ]
}
