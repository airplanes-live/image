#!/usr/bin/env bats

# Tests for dump978-fa.sh — the 978 receiver wrapper. The wrapper reads
# UAT_INPUT from the EnvironmentFile-loaded env and self-disables (exit 64)
# when UAT is not requested. State publication is owned by airplanes-978.sh;
# this wrapper does no state writing.
#
# Test hooks consumed:
#   DUMP978_FA_BIN — binary stub (avoids real /usr/bin/dump978-fa)

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/02-install-decoder/files/usr/local/share/airplanes/dump978-fa.sh"
    TMP="$(mktemp -d)"

    # Stub the binary: records argv and exits 0.
    DUMP978_FA_BIN="$TMP/dump978-fa-bin"
    cat > "$DUMP978_FA_BIN" <<EOF
#!/bin/bash
echo "executed: \$*" > "$TMP/binary-invoked"
exit 0
EOF
    chmod +x "$DUMP978_FA_BIN"
    export DUMP978_FA_BIN
}

teardown() { rm -rf "$TMP"; }

run_wrapper() {
    local uat="$1"
    if [[ -n "$uat" ]]; then
        UAT_INPUT="$uat" run bash "$SCRIPT"
    else
        UAT_INPUT="" run bash "$SCRIPT"
    fi
}

@test "01: UAT_INPUT empty → exit 64, binary not invoked" {
    run_wrapper ""
    [ "$status" -eq 64 ]
    [ ! -e "$TMP/binary-invoked" ]
}

@test "02: UAT_INPUT unset → exit 64 (treated as empty)" {
    run env -u UAT_INPUT bash "$SCRIPT"
    [ "$status" -eq 64 ]
    [ ! -e "$TMP/binary-invoked" ]
}

@test "03: UAT_INPUT=127.0.0.1:30978 → binary invoked" {
    run_wrapper "127.0.0.1:30978"
    [ "$status" -eq 0 ]
    [ -e "$TMP/binary-invoked" ]
}

@test "04: UAT_INPUT enabled → binary receives sdr + raw-port + json-port args" {
    run_wrapper "127.0.0.1:30978"
    grep -q 'driver=rtlsdr,serial=978' "$TMP/binary-invoked"
    grep -q 'raw-port 127.0.0.1:30978' "$TMP/binary-invoked"
    grep -q 'json-port 127.0.0.1:30979' "$TMP/binary-invoked"
}

@test "05: invalid UAT_INPUT → exit 64, binary not invoked" {
    run_wrapper "10.0.0.5:30978"
    [ "$status" -eq 64 ]
    [ ! -e "$TMP/binary-invoked" ]
}

@test "06: UAT_INPUT with shell metachars → exit 64 (no shell injection)" {
    run_wrapper "evil-host;rm -rf /"
    [ "$status" -eq 64 ]
    [ ! -e "$TMP/binary-invoked" ]
}

@test "07: SDR serial override works under enabled UAT_INPUT" {
    DUMP978_SDR_SERIAL="custom-serial" UAT_INPUT="127.0.0.1:30978" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q 'driver=rtlsdr,serial=custom-serial' "$TMP/binary-invoked"
}
