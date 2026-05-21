#!/usr/bin/env bats

# Tests for stage-airplanes/02-install-runtime-overlay/00-run.sh.
#
# Strategy: synthesise a release-served fixture (tarball + manifest +
# SHA256SUMS + signature) on a localhost python http.server, override the
# pubkey + download base via env, point BASE_DIR at the worktree, and invoke
# the stage's 00-run.sh. Assert the rootfs ends up with the expected
# managed_paths symlinks, the `current` link, the runtime-manifest pointer,
# and the build sentinel.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers
load lib/install_test_helpers

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    STAGE="$REPO_ROOT/stage-airplanes/02-install-runtime-overlay"

    [[ -x "$STAGE/00-run.sh" ]] || { echo "00-run.sh missing/non-exec" >&2; return 1; }
    [[ -f "$STAGE/01-run-chroot.sh" ]] || { echo "01-run-chroot.sh missing" >&2; return 1; }

    if ! command -v minisign >/dev/null 2>&1; then
        skip "minisign not installed on this host"
    fi

    HTTPD_DOC="$BATS_TEST_TMPDIR/web"
    HTTPD_LOG="$BATS_TEST_TMPDIR/httpd.log"
    PORT_FILE="$BATS_TEST_TMPDIR/httpd.port"
    install -d -m 755 "$HTTPD_DOC"

    KEY_DIR="$BATS_TEST_TMPDIR/keys"
    install -d -m 700 "$KEY_DIR"
    if ! echo "" | minisign -G -p "$KEY_DIR/test.pub" -s "$KEY_DIR/test.sec" -W >/dev/null 2>&1; then
        skip "minisign keypair generation failed"
    fi

    REL_TAG="runtime-v0.0.1"
    REL_VER="0.0.1"
    ARCH="arm64"

    REL_STAGING="$BATS_TEST_TMPDIR/rel-staging/v$REL_VER"
    install -d -m 755 \
        "$REL_STAGING/bin" \
        "$REL_STAGING/share/airplanes" \
        "$REL_STAGING/systemd" \
        "$REL_STAGING/lib/airplanes" \
        "$REL_STAGING/etc/lighttpd/conf-available" \
        "$REL_STAGING/etc/update-motd.d" \
        "$REL_STAGING/migrations"
    : > "$REL_STAGING/bin/readsb"
    chmod 755 "$REL_STAGING/bin/readsb"
    : > "$REL_STAGING/bin/dump978-fa"
    chmod 755 "$REL_STAGING/bin/dump978-fa"
    : > "$REL_STAGING/share/airplanes/readsb.sh"
    : > "$REL_STAGING/systemd/readsb.service"
    : > "$REL_STAGING/systemd/airplanes-runtime-update-recover.service"
    : > "$REL_STAGING/etc/lighttpd/conf-available/89-airplanes-978.conf"
    : > "$REL_STAGING/lib/airplanes/render-status"
    chmod 755 "$REL_STAGING/lib/airplanes/render-status"

    REL_COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "0000000000000000000000000000000000000000")"

    cat > "$REL_STAGING/manifest.json" <<JSON
{
    "version": "$REL_VER",
    "channel": "stable",
    "commit_sha": "$REL_COMMIT_SHA",
    "build_date": "2026-05-20T00:00:00Z",
    "arches": ["arm64"],
    "components": { "readsb_wiedehopf": "0000000000000000000000000000000000000000" },
    "managed_paths": [
        { "mode": "symlink",
          "link": "/etc/systemd/system/readsb.service",
          "target": "/opt/airplanes-runtime/current/systemd/readsb.service" },
        { "mode": "symlink",
          "link": "/etc/systemd/system/airplanes-runtime-update-recover.service",
          "target": "/opt/airplanes-runtime/current/systemd/airplanes-runtime-update-recover.service" },
        { "mode": "symlink",
          "link": "/usr/local/lib/airplanes/render-status",
          "target": "/opt/airplanes-runtime/current/lib/airplanes/render-status" },
        { "mode": "symlink",
          "link": "/etc/lighttpd/conf-available/89-airplanes-978.conf",
          "target": "/opt/airplanes-runtime/current/etc/lighttpd/conf-available/89-airplanes-978.conf" },
        { "mode": "symlink",
          "link": "/usr/bin/dump978-fa",
          "target": "/opt/airplanes-runtime/current/bin/dump978-fa" }
    ],
    "mutable_paths": [],
    "systemd": { "enable": [], "daemon_reload": true },
    "migrations": []
}
JSON

    install -d -m 755 "$HTTPD_DOC/$REL_TAG"
    TARBALL_NAME="${REL_TAG}-${ARCH}.tar.gz"
    ( cd "$BATS_TEST_TMPDIR/rel-staging" && tar -czf "$HTTPD_DOC/$REL_TAG/$TARBALL_NAME" \
            --owner=0 --group=0 --numeric-owner --sort=name \
            "v$REL_VER" )
    cp "$REL_STAGING/manifest.json" "$HTTPD_DOC/$REL_TAG/manifest.json"
    : > "$HTTPD_DOC/$REL_TAG/PROVENANCE.md"

    ( cd "$HTTPD_DOC/$REL_TAG" && sha256sum "$TARBALL_NAME" manifest.json > SHA256SUMS )
    echo "" | minisign -Sm "$HTTPD_DOC/$REL_TAG/SHA256SUMS" \
        -s "$KEY_DIR/test.sec" -W >/dev/null 2>&1

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
    install -d -m 755 "$ROOTFS_DIR"
}

teardown() {
    if [[ -n "${HTTPD_PID:-}" ]]; then
        kill "$HTTPD_PID" 2>/dev/null || true
    fi
}

@test "stage 02-install-runtime-overlay runs install.sh and lays the FHS symlinks" {
    run env \
        BASE_DIR="$REPO_ROOT" \
        ROOTFS_DIR="$ROOTFS_DIR" \
        ARCH="$ARCH" \
        AIRPLANES_RUNTIME_OVERLAY_TAG="$REL_TAG" \
        AIRPLANES_RUNTIME_DOWNLOAD_BASE="http://127.0.0.1:$PORT" \
        AIRPLANES_RUNTIME_BUILD_TEST_PUBKEY=1 \
        AIRPLANES_RUNTIME_MINISIGN_PUBKEY="$KEY_DIR/test.pub" \
        bash "$REPO_ROOT/stage-airplanes/02-install-runtime-overlay/00-run.sh"

    if [ "$status" -ne 0 ]; then
        echo "STAGE OUTPUT:" >&2
        echo "$output" >&2
        return 1
    fi

    # Release tree exists.
    [ -d "$ROOTFS_DIR/opt/airplanes-runtime/releases/v$REL_VER" ]
    [ -f "$ROOTFS_DIR/opt/airplanes-runtime/releases/v$REL_VER/manifest.json" ]
    [ -L "$ROOTFS_DIR/opt/airplanes-runtime/current" ]
    [ "$(readlink "$ROOTFS_DIR/opt/airplanes-runtime/current")" = "/opt/airplanes-runtime/releases/v$REL_VER" ]

    # managed_paths landed under ROOTFS_DIR with absolute on-device targets.
    [ -L "$ROOTFS_DIR/etc/systemd/system/readsb.service" ]
    [ "$(readlink "$ROOTFS_DIR/etc/systemd/system/readsb.service")" = "/opt/airplanes-runtime/current/systemd/readsb.service" ]

    [ -L "$ROOTFS_DIR/etc/systemd/system/airplanes-runtime-update-recover.service" ]
    [ "$(readlink "$ROOTFS_DIR/etc/systemd/system/airplanes-runtime-update-recover.service")" = "/opt/airplanes-runtime/current/systemd/airplanes-runtime-update-recover.service" ]

    [ -L "$ROOTFS_DIR/usr/local/lib/airplanes/render-status" ]
    [ -L "$ROOTFS_DIR/etc/lighttpd/conf-available/89-airplanes-978.conf" ]

    # Decoder binary symlinks created post-flip by install.sh.
    [ -L "$ROOTFS_DIR/usr/bin/readsb" ]
    [ "$(readlink "$ROOTFS_DIR/usr/bin/readsb")" = "/opt/airplanes-runtime/current/bin/readsb" ]
    [ -L "$ROOTFS_DIR/usr/bin/airplanes-978" ]
    [ "$(readlink "$ROOTFS_DIR/usr/bin/airplanes-978")" = "/opt/airplanes-runtime/current/bin/readsb" ]
    [ -L "$ROOTFS_DIR/usr/bin/dump978-fa" ]
    [ "$(readlink "$ROOTFS_DIR/usr/bin/dump978-fa")" = "/opt/airplanes-runtime/current/bin/dump978-fa" ]

    # Runtime-manifest pointer was wired even though build mode skips
    # systemd/health/gc.
    [ -L "$ROOTFS_DIR/etc/airplanes/runtime-manifest.json" ]
    [ "$(readlink "$ROOTFS_DIR/etc/airplanes/runtime-manifest.json")" = "/opt/airplanes-runtime/current/manifest.json" ]

    # Build sentinel for the runtime overlay source SHA.
    [ -s "$ROOTFS_DIR/etc/airplanes/.build-runtime-overlay-sha" ]

    # Scratch copy of runtime-overlay source was cleaned up.
    [ ! -d "$ROOTFS_DIR/var/tmp/airplanes-runtime-overlay-src" ]
}

@test "stage 02-install-runtime-overlay refuses without AIRPLANES_RUNTIME_OVERLAY_TAG" {
    run env \
        BASE_DIR="$REPO_ROOT" \
        ROOTFS_DIR="$ROOTFS_DIR" \
        ARCH="$ARCH" \
        AIRPLANES_RUNTIME_DOWNLOAD_BASE="http://127.0.0.1:$PORT" \
        AIRPLANES_RUNTIME_BUILD_TEST_PUBKEY=1 \
        AIRPLANES_RUNTIME_MINISIGN_PUBKEY="$KEY_DIR/test.pub" \
        bash "$REPO_ROOT/stage-airplanes/02-install-runtime-overlay/00-run.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"AIRPLANES_RUNTIME_OVERLAY_TAG"* ]]
}

@test "stage 02-install-runtime-overlay refuses when host pubkey is missing" {
    # Move the in-repo pubkey aside so the stage's host-path check fails. The
    # worktree is shared with the rest of the suite, so restore on exit.
    local pub="$REPO_ROOT/stage-airplanes/00-prep/files/usr/share/airplanes/runtime-release.pub"
    local bk="$BATS_TEST_TMPDIR/runtime-release.pub.bak"
    if [[ ! -f "$pub" ]]; then
        skip "pubkey not committed yet"
    fi
    cp "$pub" "$bk"
    rm -f "$pub"

    run env \
        BASE_DIR="$REPO_ROOT" \
        ROOTFS_DIR="$ROOTFS_DIR" \
        ARCH="$ARCH" \
        AIRPLANES_RUNTIME_OVERLAY_TAG="$REL_TAG" \
        AIRPLANES_RUNTIME_DOWNLOAD_BASE="http://127.0.0.1:$PORT" \
        bash "$REPO_ROOT/stage-airplanes/02-install-runtime-overlay/00-run.sh"

    # Restore before asserting so a failing assertion doesn't leave the
    # worktree dirty.
    cp "$bk" "$pub"

    [ "$status" -ne 0 ]
    [[ "$output" == *"runtime-release pubkey"* ]]
}
