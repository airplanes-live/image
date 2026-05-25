#!/usr/bin/env bats

# Tests the readsb health gate's two probes: aircraft.json freshness on disk
# (mtime <= 30s) and a 200 from /tar1090/data/aircraft.json against the
# probe URL base. We use a tmpdir-backed python -m http.server to serve the
# HTTP probe; the helper accepts AIRPLANES_RUNTIME_PROBE_URL_BASE so the
# test can point it at the fixture port.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
    AIRPLANES_RUNTIME_HEALTH_DEADLINE=3
    export AIRPLANES_RUNTIME_HEALTH_DEADLINE
}

@test "readsb gate: fresh aircraft.json + 200 from HTTP" {
    # Write a fresh aircraft.json (mtime is now).
    : > "$TARGET_ROOT/run/readsb/aircraft.json"
    # Start the HTTP fixture serving the three paths the gate probes.
    local doc="$BATS_TEST_TMPDIR/web"
    install -d -m 755 "$doc/tar1090/data" "$doc/tar1090" "$doc/graphs1090"
    : > "$doc/tar1090/data/aircraft.json"
    printf 'ok\n' > "$doc/tar1090/index.html"
    printf 'ok\n' > "$doc/graphs1090/index.html"

    # Start a python http.server on a free port and discover the port via
    # an inline bind-then-print-then-serve script. The PID is captured so
    # teardown can kill it.
    local logfile="$BATS_TEST_TMPDIR/httpd.log"
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
" "$doc" "$port_file" >>"$logfile" 2>&1 &
    HTTPD_PID=$!

    # Wait for the port file to appear (up to 5s).
    local i
    for (( i = 0; i < 50; i++ )); do
        [[ -s "$port_file" ]] && break
        sleep 0.1
    done
    if [[ ! -s "$port_file" ]]; then
        kill "$HTTPD_PID" 2>/dev/null || true
        skip "python http.server fixture failed to start"
    fi
    local port
    port="$(tr -d '[:space:]' < "$port_file")"

    export AIRPLANES_RUNTIME_PROBE_URL_BASE="http://127.0.0.1:$port"

    # Pre-stage the UAT state files with valid (state, reason) so those
    # gates pass — we're testing readsb today; the UAT gate has its own
    # bats file.
    printf 'state=enabled\nreason=\n' > "$TARGET_ROOT/run/dump978-fa/state"
    printf 'state=enabled\nreason=\n' > "$TARGET_ROOT/run/airplanes-978/state"

    run airplanes_runtime_run_health_gates "$TARGET_ROOT"
    kill "$HTTPD_PID" 2>/dev/null || true
    [ "$status" -eq 0 ]
}

@test "readsb gate: stale aircraft.json fails" {
    : > "$TARGET_ROOT/run/readsb/aircraft.json"
    # Backdate to 5 minutes ago.
    touch -d '5 minutes ago' "$TARGET_ROOT/run/readsb/aircraft.json"

    run airplanes_runtime_run_health_gates "$TARGET_ROOT"
    [ "$status" -ne 0 ]
}

@test "readsb gate: missing aircraft.json fails" {
    run airplanes_runtime_run_health_gates "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"aircraft.json"* ]]
}

@test "readsb gate: HTTP non-200 fails" {
    : > "$TARGET_ROOT/run/readsb/aircraft.json"
    # No HTTP fixture — point probe URL at a closed port. curl returns
    # connection-refused; the gate must fail before its deadline.
    export AIRPLANES_RUNTIME_PROBE_URL_BASE="http://127.0.0.1:1"
    printf 'state=enabled\nreason=\n' > "$TARGET_ROOT/run/dump978-fa/state"
    printf 'state=enabled\nreason=\n' > "$TARGET_ROOT/run/airplanes-978/state"

    run airplanes_runtime_run_health_gates "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"HTTP probe"* ]] || [[ "$output" == *"never returned 200"* ]]
}
