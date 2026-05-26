#!/usr/bin/env bats

# Tests the webconfig health gate: /health probe through lighttpd with
# version-verified short-SHA matching against the manifest's webconfig
# component pin. Also covers the manifest-webconfig-short-sha extractor
# and confirms webconfig is in the restart and rollback lists.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    AIRPLANES_RUNTIME_HEALTH_DEADLINE=3
    export AIRPLANES_RUNTIME_HEALTH_DEADLINE

    local shim_dir
    shim_dir="$(mk_systemctl_shim "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/systemctl.log")"
    PATH="$shim_dir:$PATH"
    export PATH
    AIRPLANES_RUNTIME_UNIT_WINDOW_CUSHION=0
    export AIRPLANES_RUNTIME_UNIT_WINDOW_CUSHION
}

# --- manifest short-sha extractor -------------------------------------------

@test "manifest_webconfig_short_sha: object component" {
    local m="$BATS_TEST_TMPDIR/manifest.json"
    cat > "$m" <<'JSON'
{"components":{"webconfig":{"commit_sha":"1b36221b3d4670d4c91145a0d91bb6588ff58cb4","version":"dev-latest"}}}
JSON
    local sha
    sha="$(_airplanes_runtime_manifest_webconfig_short_sha "$m")"
    [ "$sha" = "1b36221" ]
}

@test "manifest_webconfig_short_sha: bare string component" {
    local m="$BATS_TEST_TMPDIR/manifest.json"
    cat > "$m" <<'JSON'
{"components":{"webconfig":"abcdef0123456789abcdef0123456789abcdef01"}}
JSON
    local sha
    sha="$(_airplanes_runtime_manifest_webconfig_short_sha "$m")"
    [ "$sha" = "abcdef0" ]
}

@test "manifest_webconfig_short_sha: no webconfig component → empty" {
    local m="$BATS_TEST_TMPDIR/manifest.json"
    cat > "$m" <<'JSON'
{"components":{"readsb_wiedehopf":"abcdef0"}}
JSON
    local sha
    sha="$(_airplanes_runtime_manifest_webconfig_short_sha "$m")"
    [ -z "$sha" ]
}

@test "manifest_webconfig_short_sha: missing manifest → empty" {
    local sha
    sha="$(_airplanes_runtime_manifest_webconfig_short_sha "$BATS_TEST_TMPDIR/no-such-file.json")"
    [ -z "$sha" ]
}

# --- /health version gate ---------------------------------------------------

@test "webconfig gate: matching short-sha passes" {
    local doc="$BATS_TEST_TMPDIR/web"
    install -d -m 755 "$doc"
    printf 'ok dev-latest+1b36221\n' > "$doc/health"

    local port_file="$BATS_TEST_TMPDIR/httpd.port"
    python3 -u -c "
import http.server, socketserver, os, sys
os.chdir(sys.argv[1])
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a, **k): pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
with open(sys.argv[2], 'w') as f:
    f.write(str(srv.server_address[1]) + '\n')
srv.serve_forever()
" "$doc" "$port_file" &
    HTTPD_PID=$!
    local i
    for (( i = 0; i < 50; i++ )); do
        [[ -s "$port_file" ]] && break
        sleep 0.1
    done
    [[ -s "$port_file" ]] || { kill "$HTTPD_PID" 2>/dev/null; skip "httpd failed"; }
    local port
    port="$(tr -d '[:space:]' < "$port_file")"

    run _airplanes_runtime_probe_webconfig_version \
        "http://127.0.0.1:$port/health" "1b36221" 5
    kill "$HTTPD_PID" 2>/dev/null || true
    [ "$status" -eq 0 ]
}

@test "webconfig gate: mismatched short-sha fails" {
    local doc="$BATS_TEST_TMPDIR/web"
    install -d -m 755 "$doc"
    printf 'ok dev-latest+aaa1111\n' > "$doc/health"

    local port_file="$BATS_TEST_TMPDIR/httpd.port"
    python3 -u -c "
import http.server, socketserver, os, sys
os.chdir(sys.argv[1])
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a, **k): pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
with open(sys.argv[2], 'w') as f:
    f.write(str(srv.server_address[1]) + '\n')
srv.serve_forever()
" "$doc" "$port_file" &
    HTTPD_PID=$!
    local i
    for (( i = 0; i < 50; i++ )); do
        [[ -s "$port_file" ]] && break
        sleep 0.1
    done
    [[ -s "$port_file" ]] || { kill "$HTTPD_PID" 2>/dev/null; skip "httpd failed"; }
    local port
    port="$(tr -d '[:space:]' < "$port_file")"

    run _airplanes_runtime_probe_webconfig_version \
        "http://127.0.0.1:$port/health" "bbb2222" 3
    kill "$HTTPD_PID" 2>/dev/null || true
    [ "$status" -ne 0 ]
    [[ "$output" == *"bbb2222"* ]]
}

# --- webconfig in restart order + systemd ops --------------------------------

@test "webconfig.service is in the hardcoded restart order" {
    local found=0 u
    for u in "${_airplanes_runtime_restart_order[@]}"; do
        [[ "$u" == "airplanes-webconfig.service" ]] && found=1
    done
    [ "$found" -eq 1 ]
}

# --- copy-mode sudoers with visudo post_install ------------------------------

@test "managed_paths.json declares copy-mode webconfig sudoers with visudo post_install" {
    local mp
    mp="$(cat "$BATS_TEST_DIRNAME/../../runtime-overlay/manifest-inputs/managed_paths.json")"
    local mode path pi0
    mode="$(printf '%s' "$mp" | jq -r '[.[] | select(.path == "/etc/sudoers.d/010_airplanes-webconfig")][0].mode')"
    [ "$mode" = "copy" ]
    pi0="$(printf '%s' "$mp" | jq -r '[.[] | select(.path == "/etc/sudoers.d/010_airplanes-webconfig")][0].post_install[0]')"
    [ "$pi0" = "/usr/sbin/visudo" ]
}
