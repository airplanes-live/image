#!/usr/bin/env bats

# Tests the aggregate unit-health gate (_airplanes_runtime_probe_units_active)
# and its time-span parser (DEV-472). The gate closes the crash-loop blind
# spot: a Restart=always unit reading `active` momentarily between failures,
# or lighttpd serving a 200 for a dead tar1090/graphs1090.
#
# systemctl is stubbed via the shared shim, whose `show … --value` defaults
# are overridable per (unit, property) through $SYSTEMCTL_STUB_DIR.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

UNITS=(readsb.service tar1090.service graphs1090.service)

setup() {
    source_install_lib
    SHIM_DIR="$(mk_systemctl_shim "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/systemctl.log")"
    PATH="$SHIM_DIR:$PATH"
    export PATH
    SYSTEMCTL_STUB_DIR="$BATS_TEST_TMPDIR/stub"
    install -d -m 755 "$SYSTEMCTL_STUB_DIR"
    export SYSTEMCTL_STUB_DIR
    # Short shared window so the stability hold is ~1s in tests.
    export AIRPLANES_RUNTIME_UNIT_WINDOW_CUSHION=0
}

stub() { # <unit> <prop> <value>
    printf '%s\n' "$3" > "$SYSTEMCTL_STUB_DIR/$1.$2"
}

@test "all units active + stable → pass" {
    run _airplanes_runtime_probe_units_active 3 "${UNITS[@]}"
    [ "$status" -eq 0 ]
}

@test "a unit stuck activating (auto-restart) → fail" {
    stub tar1090.service ActiveState activating
    run _airplanes_runtime_probe_units_active 3 "${UNITS[@]}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not all units active"* ]]
}

@test "a unit with non-success Result → fail" {
    stub tar1090.service Result exit-code
    run _airplanes_runtime_probe_units_active 3 "${UNITS[@]}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unstable"* ]]
}

@test "a unit flapping (NRestarts increments mid-window) → fail" {
    # Bespoke systemctl returning an ever-incrementing NRestarts so the
    # hold-window re-check sees it differ from the snapshot.
    local nrfile="$BATS_TEST_TMPDIR/nr"
    printf '0\n' > "$nrfile"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'NRFILE=%q\n' "$nrfile"
        cat <<'EOF'
prop=""; args=("$@")
for ((i=0;i<${#args[@]};i++)); do [[ "${args[i]}" == "-p" ]] && prop="${args[i+1]}"; done
case "$prop" in
    ActiveState) echo active ;;
    SubState)    echo running ;;
    Result)      echo success ;;
    RestartUSec) echo 0 ;;
    NRestarts)   n=$(cat "$NRFILE"); echo "$n"; echo $((n+1)) > "$NRFILE" ;;
    *)           echo "" ;;
esac
exit 0
EOF
    } > "$SHIM_DIR/systemctl"
    chmod 755 "$SHIM_DIR/systemctl"

    run _airplanes_runtime_probe_units_active 3 "${UNITS[@]}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unstable"* ]]
}

@test "missing systemctl → fail closed" {
    PATH= run _airplanes_runtime_probe_units_active 3 readsb.service
    [ "$status" -ne 0 ]
    [[ "$output" == *"systemctl unavailable"* ]]
}

@test "unparseable RestartUSec → fail closed" {
    stub tar1090.service RestartUSec not-a-timespan
    run _airplanes_runtime_probe_units_active 3 "${UNITS[@]}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unparseable RestartUSec"* ]]
}

@test "time-span parser: common forms" {
    [ "$(_airplanes_runtime_parse_timespan_seconds '30s')" = "30" ]
    [ "$(_airplanes_runtime_parse_timespan_seconds '100ms')" = "1" ]
    [ "$(_airplanes_runtime_parse_timespan_seconds '1min 30s')" = "90" ]
    [ "$(_airplanes_runtime_parse_timespan_seconds '0')" = "0" ]
    [ "$(_airplanes_runtime_parse_timespan_seconds 'infinity')" = "0" ]
    # Bare integer is microseconds; 2_000_000us = 2s.
    [ "$(_airplanes_runtime_parse_timespan_seconds '2000000')" = "2" ]
}

@test "time-span parser: garbage fails non-zero" {
    run _airplanes_runtime_parse_timespan_seconds 'garbage'
    [ "$status" -ne 0 ]
}

@test "time-span parser: trailing garbage after a valid token fails closed" {
    run _airplanes_runtime_parse_timespan_seconds '1s xyz'
    [ "$status" -ne 0 ]
    run _airplanes_runtime_parse_timespan_seconds '30s 99'
    [ "$status" -ne 0 ]
}

@test "tar1090 + graphs1090 are in the restart order (gate validates new units)" {
    # If these aren't restarted on update, the unit gate would check the prior
    # release's still-running process instead of the new unit files.
    printf '%s\n' "${_airplanes_runtime_restart_order[@]}" | grep -qx 'tar1090.service'
    printf '%s\n' "${_airplanes_runtime_restart_order[@]}" | grep -qx 'graphs1090.service'
}
