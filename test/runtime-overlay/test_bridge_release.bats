#!/usr/bin/env bats

# Bridge-release verification: install a "release N+1" (a manifest carrying
# the new schema fields — manifest_schema_version, installer_min_version,
# compat.base_os_codename) using "release N's" updater (this in-tree
# install-common.sh + install.sh). Proves the floor is enforced from the
# first schema-using release: a forward-compatible release installs cleanly,
# and a release demanding a newer updater is refused before any mutation.
#
# End-to-end against a synthetic root, mirroring test_install_runtime_smoke.

bats_require_minimum_version 1.5.0

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
    install -d -m 755 "$TARGET_ROOT/etc/airplanes" "$TARGET_ROOT/etc"
    printf 'stable\n' > "$TARGET_ROOT/etc/airplanes/release-channel"
    # The base OS the release will target. The compat preflight reads this.
    printf 'VERSION_CODENAME=trixie\n' > "$TARGET_ROOT/etc/os-release"

    KEY_DIR="$BATS_TEST_TMPDIR/keys"
    install -d -m 700 "$KEY_DIR"
    echo "" | minisign -G -p "$KEY_DIR/test.pub" -s "$KEY_DIR/test.sec" -W >/dev/null 2>&1
    REL_TAG="v0.0.2"
    REL_VER="0.0.2"
    ARCH="arm64"
    REL_STAGING="$BATS_TEST_TMPDIR/rel-staging/v$REL_VER"
    install -d -m 755 \
        "$REL_STAGING/bin" "$REL_STAGING/share/airplanes" \
        "$REL_STAGING/systemd" "$REL_STAGING/lib/airplanes" "$REL_STAGING/migrations"
    : > "$REL_STAGING/bin/readsb"
    chmod 755 "$REL_STAGING/bin/readsb"
    : > "$REL_STAGING/share/airplanes/readsb.sh"
    : > "$REL_STAGING/systemd/readsb.service"

    HTTPD_DOC="$BATS_TEST_TMPDIR/web"
    install -d -m 755 "$HTTPD_DOC/$REL_TAG"
    install -d -m 755 "$HTTPD_DOC/tar1090/data" "$HTTPD_DOC/tar1090" "$HTTPD_DOC/graphs1090"
    : > "$HTTPD_DOC/tar1090/data/aircraft.json"
    printf 'ok' > "$HTTPD_DOC/tar1090/index.html"
    printf 'ok' > "$HTTPD_DOC/graphs1090/index.html"

    : > "$TARGET_ROOT/run/readsb/aircraft.json"
    printf 'state=enabled\nreason=\n' > "$TARGET_ROOT/run/dump978-fa/state"
    printf 'state=enabled\nreason=\n' > "$TARGET_ROOT/run/airplanes-978/state"
}

teardown() {
    if [[ -n "${HTTPD_PID:-}" ]]; then
        kill "$HTTPD_PID" 2>/dev/null || true
    fi
}

# Write a release manifest carrying the new schema fields. $1 = installer_min,
# $2 = manifest_schema_version.
write_manifest() {
    local installer_min="$1" schema_ver="$2"
    cat > "$REL_STAGING/manifest.json" <<JSON
{
    "manifest_schema_version": $schema_ver,
    "installer_min_version": "$installer_min",
    "version": "$REL_VER",
    "channel": "stable",
    "commit_sha": "0000000000000000000000000000000000000000",
    "build_date": "2026-05-20T00:00:00Z",
    "arches": ["arm64"],
    "compat": { "base_os_codename": "trixie" },
    "components": {
        "readsb_wiedehopf": { "commit_sha": "0000000", "version": "9.9.9" }
    },
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
}

start_httpd() {
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
    [[ -s "$PORT_FILE" ]] || { kill "$HTTPD_PID" 2>/dev/null || true; skip "http.server failed to start"; }
    PORT="$(tr -d '[:space:]' < "$PORT_FILE")"
}

run_install() {
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
        AIRPLANES_RUNTIME_INSTALLER_VERSION="1.0.0" \
        AIRPLANES_RUNTIME_INSTALLER_SCHEMA_VERSION="1" \
        PATH="$SHIM_DIR:$PATH" \
        bash "$REPO_ROOT/runtime-overlay/install.sh" --runtime
}

@test "bridge: release N+1 installs cleanly with release N's updater" {
    # Forward-compatible: schema 1, installer_min 1.0.0, base trixie.
    write_manifest "1.0.0" 1
    start_httpd
    run run_install
    if [ "$status" -ne 0 ]; then
        echo "$output"
        return 1
    fi
    [ -d "$TARGET_ROOT/opt/airplanes-runtime/releases/v$REL_VER" ]
    [ -L "$TARGET_ROOT/opt/airplanes-runtime/current" ]
    [ -L "$TARGET_ROOT/etc/systemd/system/readsb.service" ]
    # Component-object pin was accepted (no schema rejection).
    run jq -e '.components.readsb_wiedehopf.version == "9.9.9"' \
        "$TARGET_ROOT/opt/airplanes-runtime/releases/v$REL_VER/manifest.json"
    [ "$status" -eq 0 ]
}

@test "bridge: release demanding a newer updater is refused pre-mutation" {
    write_manifest "2.0.0" 1
    start_httpd
    run run_install
    [ "$status" -ne 0 ]
    # No release dir laid down — refused before extraction.
    [ ! -d "$TARGET_ROOT/opt/airplanes-runtime/releases/v$REL_VER" ]
}

@test "bridge: release with a newer schema version is refused pre-mutation" {
    write_manifest "1.0.0" 2
    start_httpd
    run run_install
    [ "$status" -ne 0 ]
    [ ! -d "$TARGET_ROOT/opt/airplanes-runtime/releases/v$REL_VER" ]
}
