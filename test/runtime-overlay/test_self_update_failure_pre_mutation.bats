#!/usr/bin/env bats

# Pre-mutation failures (download / verify / preflight) record
# FAILED_PRE_MUTATION without ever touching on-disk state. The next
# attempt clears this terminal state and re-runs from CLEAN.

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

    LOCK_DIR="$BATS_TEST_TMPDIR/lockdir"
    install -d -m 755 "$LOCK_DIR"
    LOCK_FILE="$LOCK_DIR/runtime-update.lock"
}

@test "download failure records FAILED_PRE_MUTATION and leaves on-disk untouched" {
    # No HTTP server staged; the download will 404 / refuse.
    run env \
        AIRPLANES_BUILD_MODE=0 \
        AIRPLANES_RUNTIME_ARCH_OVERRIDE="arm64" \
        AIRPLANES_RUNTIME_ROOT="$TARGET_ROOT" \
        AIRPLANES_RUNTIME_DOWNLOAD_BASE="http://127.0.0.1:1" \
        AIRPLANES_RUNTIME_MINISIGN_PUBKEY="$KEY_DIR/test.pub" \
        AIRPLANES_RUNTIME_OVERLAY_TAG="v0.0.1" \
        AIRPLANES_RUNTIME_LOCK_FILE="$LOCK_FILE" \
        AIRPLANES_RUNTIME_INSTALL_COMMON="$REPO_ROOT/runtime-overlay/scripts/lib/install-common.sh" \
        PATH="$SHIM_DIR:$PATH" \
        bash "$REPO_ROOT/runtime-overlay/src/lib/runtime-self-update.sh"

    [ "$status" -ne 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "FAILED_PRE_MUTATION" ]
    # failure_reason captured in the state file.
    grep -E '^failure_reason=download_failed$' \
        "$TARGET_ROOT/var/lib/airplanes-runtime-upgrade/upgrade-state"

    # Critical: NO release dir or current symlink were created (no
    # mutation happened).
    [ ! -L "$TARGET_ROOT/opt/airplanes-runtime/current" ]
    run find "$TARGET_ROOT/opt/airplanes-runtime/releases" -mindepth 1 -maxdepth 1 -type d
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "compat preflight failure records FAILED_PRE_MUTATION" {
    if ! command -v minisign >/dev/null 2>&1; then
        skip "minisign required"
    fi

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

    # Manifest declares an impossible feed-contract requirement so the
    # preflight rejects.
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
    "migrations": [],
    "compat": { "requires_feed_contract": ">=99999.0.0" }
}
JSON

    HTTPD_DOC="$BATS_TEST_TMPDIR/web"
    install -d -m 755 "$HTTPD_DOC/$REL_TAG"
    stage_product_runtime_assets "$REL_STAGING" "$HTTPD_DOC/$REL_TAG" "$ARCH" "$KEY_DIR/test.sec"

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

    run env \
        AIRPLANES_BUILD_MODE=0 \
        AIRPLANES_RUNTIME_ARCH_OVERRIDE="arm64" \
        AIRPLANES_RUNTIME_ROOT="$TARGET_ROOT" \
        AIRPLANES_RUNTIME_DOWNLOAD_BASE="http://127.0.0.1:$PORT" \
        AIRPLANES_RUNTIME_MINISIGN_PUBKEY="$KEY_DIR/test.pub" \
        AIRPLANES_RUNTIME_OVERLAY_TAG="$REL_TAG" \
        AIRPLANES_RUNTIME_LOCK_FILE="$LOCK_FILE" \
        AIRPLANES_RUNTIME_INSTALL_COMMON="$REPO_ROOT/runtime-overlay/scripts/lib/install-common.sh" \
        PATH="$SHIM_DIR:$PATH" \
        bash "$REPO_ROOT/runtime-overlay/src/lib/runtime-self-update.sh"

    kill "$HTTPD_PID" 2>/dev/null || true

    [ "$status" -ne 0 ]
    [ "$(read_state "$TARGET_ROOT")" = "FAILED_PRE_MUTATION" ]
    [ ! -L "$TARGET_ROOT/opt/airplanes-runtime/current" ]
}
