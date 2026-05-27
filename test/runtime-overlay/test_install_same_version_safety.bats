#!/usr/bin/env bats

# Verifies install.sh refuses to rm -rf a release dir that `current`
# currently points at — a same-version rerun must not destroy the live
# release.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    if ! command -v minisign >/dev/null 2>&1; then
        skip "minisign not installed on this host"
    fi

    # Set up a fixture release the same way the build-mode test does.
    KEY_DIR="$BATS_TEST_TMPDIR/keys"
    install -d -m 700 "$KEY_DIR"
    echo "" | minisign -G -p "$KEY_DIR/test.pub" -s "$KEY_DIR/test.sec" -W >/dev/null 2>&1
    REL_TAG="v0.0.1"
    REL_VER="0.0.1"
    ARCH="arm64"
    REL_STAGING="$BATS_TEST_TMPDIR/rel-staging/v$REL_VER"
    install -d -m 755 "$REL_STAGING/bin" "$REL_STAGING/share/airplanes" \
                      "$REL_STAGING/systemd" "$REL_STAGING/lib/airplanes" \
                      "$REL_STAGING/migrations"
    : > "$REL_STAGING/bin/readsb"
    chmod 755 "$REL_STAGING/bin/readsb"

    REL_COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "0000000000000000000000000000000000000000")"
    cat > "$REL_STAGING/manifest.json" <<JSON
{
    "version": "$REL_VER",
    "channel": "stable",
    "commit_sha": "$REL_COMMIT_SHA",
    "build_date": "2026-05-20T00:00:00Z",
    "arches": ["arm64"],
    "components": { "readsb_wiedehopf": "0000000" },
    "managed_paths": [],
    "mutable_paths": [],
    "systemd": { "enable": [], "daemon_reload": true },
    "migrations": []
}
JSON

    HTTPD_DOC="$BATS_TEST_TMPDIR/web"
    install -d -m 755 "$HTTPD_DOC/$REL_TAG"
    stage_product_runtime_assets "$REL_STAGING" "$HTTPD_DOC/$REL_TAG" "$ARCH" "$KEY_DIR/test.sec"

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

    ROOTFS_DIR="$BATS_TEST_TMPDIR/rootfs"
    install -d -m 755 "$ROOTFS_DIR/opt/airplanes-runtime/releases/v$REL_VER"
    : > "$ROOTFS_DIR/opt/airplanes-runtime/releases/v$REL_VER/sentinel"
    # Wire up `current` to point AT the same dir we're about to extract.
    ln -s "/opt/airplanes-runtime/releases/v$REL_VER" "$ROOTFS_DIR/opt/airplanes-runtime/current"
}

teardown() {
    if [[ -n "${HTTPD_PID:-}" ]]; then
        kill "$HTTPD_PID" 2>/dev/null || true
    fi
}

@test "build mode refuses to clobber the active release dir" {
    # We use build mode purely because it skips health gates and systemd
    # ops. The relevant guard runs in install.sh before extract, regardless
    # of mode.
    run env \
        AIRPLANES_BUILD_MODE=1 \
        ARCH="$ARCH" \
        ROOTFS_DIR="$ROOTFS_DIR" \
        AIRPLANES_RUNTIME_OVERLAY_TAG="$REL_TAG" \
        AIRPLANES_RUNTIME_DOWNLOAD_BASE="http://127.0.0.1:$PORT" \
        AIRPLANES_RUNTIME_MINISIGN_PUBKEY="$KEY_DIR/test.pub" \
        bash "$REPO_ROOT/runtime-overlay/install.sh" --build-mode
    [ "$status" -ne 0 ]
    [[ "$output" == *"active 'current' target"* ]]
    # The sentinel from the prior release MUST still exist — the install
    # did NOT rm -rf the live release.
    [ -f "$ROOTFS_DIR/opt/airplanes-runtime/releases/v$REL_VER/sentinel" ]
}
