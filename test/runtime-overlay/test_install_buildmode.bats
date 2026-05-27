#!/usr/bin/env bats

# End-to-end build-mode test:
# Spins up a python http.server serving a minimally-valid release (tarball,
# manifest.json, SHA256SUMS, SHA256SUMS.minisig signed with a tmpdir
# minisign keypair, PROVENANCE.md), invokes runtime-overlay/install.sh
# --build-mode against a tmpdir ROOTFS_DIR, and asserts the release dir
# + symlinks land correctly under the staged rootfs.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    if ! command -v minisign >/dev/null 2>&1; then
        skip "minisign not installed on this host"
    fi

    HTTPD_DOC="$BATS_TEST_TMPDIR/web"
    HTTPD_LOG="$BATS_TEST_TMPDIR/httpd.log"
    PORT_FILE="$BATS_TEST_TMPDIR/httpd.port"
    install -d -m 755 "$HTTPD_DOC"

    # Generate a minisign keypair for the fixture release.
    KEY_DIR="$BATS_TEST_TMPDIR/keys"
    install -d -m 700 "$KEY_DIR"
    if ! echo "" | minisign -G -p "$KEY_DIR/test.pub" -s "$KEY_DIR/test.sec" -W >/dev/null 2>&1; then
        skip "minisign keypair generation failed"
    fi

    # Stage the release tree.
    REL_TAG="v0.0.1"
    REL_VER="0.0.1"
    ARCH="arm64"
    REL_STAGING="$BATS_TEST_TMPDIR/rel-staging/v$REL_VER"
    install -d -m 755 \
        "$REL_STAGING/bin" \
        "$REL_STAGING/share/airplanes" \
        "$REL_STAGING/systemd" \
        "$REL_STAGING/lib/airplanes" \
        "$REL_STAGING/migrations"
    : > "$REL_STAGING/bin/readsb"
    chmod 755 "$REL_STAGING/bin/readsb"
    : > "$REL_STAGING/share/airplanes/readsb.sh"
    : > "$REL_STAGING/systemd/readsb.service"

    # In build mode install.sh cross-checks manifest.commit_sha against
    # git rev-parse HEAD of the worktree containing install.sh. Pin the
    # manifest's commit_sha to whatever the worktree currently is.
    REL_COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "0000000000000000000000000000000000000000")"

    # Compose a minimal manifest.json. Build-mode skips systemd ops and
    # health gates; we only need managed_paths to be exercisable.
    cat > "$REL_STAGING/manifest.json" <<JSON
{
    "version": "$REL_VER",
    "channel": "stable",
    "commit_sha": "$REL_COMMIT_SHA",
    "build_date": "2026-05-20T00:00:00Z",
    "arches": ["arm64"],
    "components": { "readsb_wiedehopf": "0000000" },
    "managed_paths": [
        { "mode": "symlink",
          "link": "/etc/systemd/system/readsb.service",
          "target": "/opt/airplanes-runtime/current/systemd/readsb.service" },
        { "mode": "symlink",
          "link": "/usr/local/share/airplanes/readsb.sh",
          "target": "/opt/airplanes-runtime/current/share/airplanes/readsb.sh" }
    ],
    "mutable_paths": [],
    "systemd": { "enable": [], "daemon_reload": true },
    "migrations": []
}
JSON

    # Tar up the release tree. The leading dir is `v$REL_VER`, which the
    # install helper strips via --strip-components=1 on extract.
    install -d -m 755 "$HTTPD_DOC/$REL_TAG"
    TARBALL_NAME="runtime-overlay-${ARCH}.tar.gz"
    ( cd "$BATS_TEST_TMPDIR/rel-staging" && tar -czf "$HTTPD_DOC/$REL_TAG/$TARBALL_NAME" \
            --owner=0 --group=0 --numeric-owner --sort=name \
            "v$REL_VER" )
    cp "$REL_STAGING/manifest.json" "$HTTPD_DOC/$REL_TAG/runtime-manifest.json"
    : > "$HTTPD_DOC/$REL_TAG/PROVENANCE.md"

    # SHA256SUMS covers tarball + manifest.
    ( cd "$HTTPD_DOC/$REL_TAG" && sha256sum "$TARBALL_NAME" runtime-manifest.json > runtime-SHA256SUMS )
    # Sign SHA256SUMS with the test key. -W = no password prompt.
    echo "" | minisign -Sm "$HTTPD_DOC/$REL_TAG/runtime-SHA256SUMS" \
        -s "$KEY_DIR/test.sec" -W >/dev/null 2>&1

    # Spawn the http.server.
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

@test "build mode lays the release tree + symlinks under ROOTFS_DIR" {
    run env \
        AIRPLANES_BUILD_MODE=1 \
        ARCH="$ARCH" \
        ROOTFS_DIR="$ROOTFS_DIR" \
        AIRPLANES_RUNTIME_OVERLAY_TAG="$REL_TAG" \
        AIRPLANES_RUNTIME_DOWNLOAD_BASE="http://127.0.0.1:$PORT" \
        AIRPLANES_RUNTIME_MINISIGN_PUBKEY="$KEY_DIR/test.pub" \
        bash "$REPO_ROOT/runtime-overlay/install.sh" --build-mode
    if [ "$status" -ne 0 ]; then
        echo "$output"
        return 1
    fi
    [ -d "$ROOTFS_DIR/opt/airplanes-runtime/releases/v$REL_VER" ]
    [ -f "$ROOTFS_DIR/opt/airplanes-runtime/releases/v$REL_VER/manifest.json" ]
    [ -f "$ROOTFS_DIR/opt/airplanes-runtime/releases/v$REL_VER/bin/readsb" ]
    [ -L "$ROOTFS_DIR/opt/airplanes-runtime/current" ]
    # The current symlink target string is the on-device-canonical path
    # (NOT rebased through ROOTFS_DIR), because the link lives in the
    # rootfs but resolves on the real device where /opt/airplanes-runtime
    # is the actual on-disk root.
    [ "$(readlink "$ROOTFS_DIR/opt/airplanes-runtime/current")" = "/opt/airplanes-runtime/releases/v$REL_VER" ]
    # managed_paths laid down under ROOTFS_DIR.
    [ -L "$ROOTFS_DIR/etc/systemd/system/readsb.service" ]
    [ "$(readlink "$ROOTFS_DIR/etc/systemd/system/readsb.service")" = "/opt/airplanes-runtime/current/systemd/readsb.service" ]
    # Decoder binary symlinks created.
    [ -L "$ROOTFS_DIR/usr/bin/readsb" ]
    [ -L "$ROOTFS_DIR/usr/bin/airplanes-978" ]
}

@test "build mode rejects a tampered SHA256SUMS" {
    # Corrupt the SHA256SUMS file post-staging.
    printf 'deadbeef  runtime-overlay-arm64.tar.gz\n' > "$HTTPD_DOC/$REL_TAG/runtime-SHA256SUMS"
    # Re-sign so the minisign verify passes but the sha check fails.
    echo "" | minisign -Sm "$HTTPD_DOC/$REL_TAG/runtime-SHA256SUMS" \
        -s "$KEY_DIR/test.sec" -W >/dev/null 2>&1
    run env \
        AIRPLANES_BUILD_MODE=1 ARCH="$ARCH" \
        ROOTFS_DIR="$ROOTFS_DIR" \
        AIRPLANES_RUNTIME_OVERLAY_TAG="$REL_TAG" \
        AIRPLANES_RUNTIME_DOWNLOAD_BASE="http://127.0.0.1:$PORT" \
        AIRPLANES_RUNTIME_MINISIGN_PUBKEY="$KEY_DIR/test.pub" \
        bash "$REPO_ROOT/runtime-overlay/install.sh" --build-mode
    [ "$status" -ne 0 ]
    [[ "$output" == *"SHA256"* || "$output" == *"missing one of"* ]]
}

@test "build mode rejects an invalid minisign signature" {
    # Generate a SECOND keypair and re-sign with it; the installer uses
    # the first one.
    local k2="$BATS_TEST_TMPDIR/keys2"
    install -d -m 700 "$k2"
    echo "" | minisign -G -p "$k2/test.pub" -s "$k2/test.sec" -W >/dev/null 2>&1
    echo "" | minisign -Sm "$HTTPD_DOC/$REL_TAG/runtime-SHA256SUMS" \
        -s "$k2/test.sec" -W -x "$HTTPD_DOC/$REL_TAG/runtime-SHA256SUMS.minisig" >/dev/null 2>&1
    run env \
        AIRPLANES_BUILD_MODE=1 ARCH="$ARCH" \
        ROOTFS_DIR="$ROOTFS_DIR" \
        AIRPLANES_RUNTIME_OVERLAY_TAG="$REL_TAG" \
        AIRPLANES_RUNTIME_DOWNLOAD_BASE="http://127.0.0.1:$PORT" \
        AIRPLANES_RUNTIME_MINISIGN_PUBKEY="$KEY_DIR/test.pub" \
        bash "$REPO_ROOT/runtime-overlay/install.sh" --build-mode
    [ "$status" -ne 0 ]
    [[ "$output" == *"minisign"* ]]
}
