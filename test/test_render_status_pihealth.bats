#!/usr/bin/env bats

# Pi-health row tests for render-status. Stubs the airplanes-webconfig
# binary via PATHS_PIHEALTH_BIN and verifies the Hardware row renders
# (or doesn't) under the expected conditions.

bats_require_minimum_version 1.5.0

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/06b-console-dashboard/files/usr/local/lib/airplanes/render-status"
    LOGO="$BATS_TEST_DIRNAME/../stage-airplanes/06b-console-dashboard/files/usr/local/share/airplanes/logo.txt"
    BANNER="$BATS_TEST_DIRNAME/../stage-airplanes/06b-console-dashboard/files/usr/local/share/airplanes/banner.txt"
    BANNER_NARROW="$BATS_TEST_DIRNAME/../stage-airplanes/06b-console-dashboard/files/usr/local/share/airplanes/banner-narrow.txt"
    ICON="$BATS_TEST_DIRNAME/../stage-airplanes/06b-console-dashboard/files/usr/local/share/airplanes/icon.txt"
    TMP="$(mktemp -d)"
    export AIRPLANES_STATUS_TAGLINE_INDEX=0

    # All PATHS_* default to /nonexistent so an un-overridden test gets the
    # "all sources missing" baseline. The pi-health binary path is the one
    # we'll override per-test.
    export PATHS_FEEDER_ID="$TMP/nx-feeder-id"
    export PATHS_RELEASE_CHANNEL="$TMP/nx-channel"
    export PATHS_MANIFEST="$TMP/nx-manifest"
    export PATHS_FEED_ENV="$TMP/nx-feed-env"
    export PATHS_CLAIM_SECRET="$TMP/nx-claim-secret"
    export PATHS_CLAIM_PENDING="$TMP/nx-claim-pending"
    export PATHS_CLAIM_VERSION="$TMP/nx-claim-version"
    export PATHS_AIRCRAFT_JSON="$TMP/nx-aircraft"
    export PATHS_THERMAL="$TMP/nx-thermal"
    export PATHS_LOGO="$LOGO"
    export PATHS_BANNER="$BANNER"
    export PATHS_BANNER_NARROW="$BANNER_NARROW"
    export PATHS_ICON="$ICON"
    export PATHS_STATE_FILE_MLAT="$TMP/nx-mlat-state"
    export PATHS_STATE_FILE_FEED="$TMP/nx-feed-state"
    export PATHS_STATE_FILE_978="$TMP/nx-978-state"
    export PATHS_STATE_FILE_DUMP978FA="$TMP/nx-dump978fa-state"
    export PATHS_STATE_READER_LIB="$TMP/nx-state-reader-lib"
    export PATHS_SYSFS_NET="$TMP/sysfs-net"
    # Default: no binary configured. Individual tests point this at a stub
    # script (or deliberately leave it pointing at /nonexistent to test the
    # missing-binary fallback).
    export PATHS_PIHEALTH_BIN="$TMP/nx-airplanes-webconfig"
    export TERM=dumb  # disable color so non-color assertions match plain text

    install_default_nmcli_stub

    # shellcheck source=/dev/null
    source "$SCRIPT"
}

install_default_nmcli_stub() {
    local shim="$TMP/shim-nmcli"
    mkdir -p "$shim"
    cat > "$shim/nmcli" <<EOF
#!/bin/bash
exit 0
EOF
    chmod +x "$shim/nmcli"
    PATH="$shim:$PATH"
}

# Install a stub airplanes-webconfig that emits the given line and exits 0.
# The line should be the full "severity<TAB>summary" wire shape (or
# malformed, for negative-path tests).
install_pihealth_stub() {
    local line="$1"
    local stub_path="$TMP/airplanes-webconfig-stub"
    cat > "$stub_path" <<EOF
#!/bin/bash
printf '%s\n' "$line"
exit 0
EOF
    chmod +x "$stub_path"
    export PATHS_PIHEALTH_BIN="$stub_path"
}

teardown() { rm -rf "$TMP"; }

# Find the Hardware row in STATUS_LINES (after stripping ANSI). Stdout is
# the matching line, or empty if none.
find_hardware_row() {
    local row stripped
    for row in "${STATUS_LINES[@]}"; do
        stripped="$(printf '%s' "$row" | sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g')"
        if [[ "$stripped" == Hardware* ]]; then
            printf '%s' "$stripped"
            return 0
        fi
    done
    return 1
}

# === pihealth_color helper (independent of TERM) ===

@test "pihealth_color: ok -> C_OK, warn -> C_WARN, err -> C_FAIL, others -> C_DIM" {
    # Override the (empty under TERM=dumb) constants with sentinels so we
    # can verify the mapping without needing a real TTY.
    C_OK=__OK__
    C_WARN=__WARN__
    C_FAIL=__FAIL__
    C_DIM=__DIM__
    [[ "$(pihealth_color ok)"   == "__OK__"   ]]
    [[ "$(pihealth_color warn)" == "__WARN__" ]]
    [[ "$(pihealth_color err)"  == "__FAIL__" ]]
    [[ "$(pihealth_color na)"   == "__DIM__"  ]]
    [[ "$(pihealth_color bogus)" == "__DIM__" ]]
    [[ "$(pihealth_color "")"   == "__DIM__"  ]]
}

# === Full layout — wide panel ===

@test "build_status_lines_full: ok severity renders a Hardware row with the summary" {
    install_pihealth_stub $'ok\thealthy'
    collect_status_data live
    build_status_lines_full live
    local row
    row="$(find_hardware_row)"
    [[ "$row" == *"Hardware"* ]]
    [[ "$row" == *"healthy"* ]]
}

@test "build_status_lines_full: warn severity renders the full summary text" {
    install_pihealth_stub $'warn\tundervoltage history * 78C'
    collect_status_data live
    build_status_lines_full live
    local row
    row="$(find_hardware_row)"
    [[ "$row" == *"undervoltage history * 78C"* ]]
}

@test "build_status_lines_full: err severity renders worst-case summary intact" {
    install_pihealth_stub $'err\tundervolted now * throttling now * arm freq capped now'
    collect_status_data live
    build_status_lines_full live
    local row
    row="$(find_hardware_row)"
    [[ "$row" == *"undervolted now * throttling now * arm freq capped now"* ]]
}

@test "build_status_lines_full: na severity still surfaces probe failed text" {
    install_pihealth_stub $'na\tprobe failed'
    collect_status_data live
    build_status_lines_full live
    local row
    row="$(find_hardware_row)"
    [[ "$row" == *"probe failed"* ]]
}

# === Failure modes — wide panel ===

@test "build_status_lines_full: missing binary omits the Hardware row" {
    # Default PATHS_PIHEALTH_BIN points at a non-existent path.
    collect_status_data live
    build_status_lines_full live
    ! find_hardware_row
}

@test "build_status_lines_full: malformed output (no tab) omits the row" {
    install_pihealth_stub "weirdoutput"
    collect_status_data live
    build_status_lines_full live
    ! find_hardware_row
}

@test "build_status_lines_full: invalid severity token omits the row" {
    install_pihealth_stub $'bogus\tsomething'
    collect_status_data live
    build_status_lines_full live
    ! find_hardware_row
}

@test "build_status_lines_full: multiline output uses only the first line" {
    install_pihealth_stub $'ok\thealthy\nLEAK_THIS_LINE'
    collect_status_data live
    build_status_lines_full live
    local row
    row="$(find_hardware_row)"
    [[ "$row" == *"healthy"* ]]
    [[ "$row" != *"LEAK_THIS_LINE"* ]]
    # And the leak must not appear anywhere else in the output either.
    local r
    for r in "${STATUS_LINES[@]}"; do
        [[ "$r" != *"LEAK_THIS_LINE"* ]]
    done
}

@test "build_status_lines_full: control bytes in summary are stripped" {
    # The stub injects an ANSI escape sequence in the summary. The defence
    # in collect_status_data must strip it before it reaches STATUS_LINES.
    install_pihealth_stub $'ok\thealthy\x1b[31mEVIL'
    collect_status_data live
    build_status_lines_full live
    local row
    row="$(find_hardware_row)"
    # No surviving ESC bytes inside the row body.
    [[ "$row" != *$'\x1b[31m'* ]]
}

@test "build_status_lines_full: slow probe times out and the row is omitted" {
    # Sleep longer than the 3s shell timeout. The test takes ~3s but the
    # row must not appear.
    local stub="$TMP/airplanes-webconfig-slow"
    cat > "$stub" <<'EOF'
#!/bin/bash
sleep 10
printf 'ok\thealthy\n'
EOF
    chmod +x "$stub"
    export PATHS_PIHEALTH_BIN="$stub"
    collect_status_data live
    build_status_lines_full live
    ! find_hardware_row
}

@test "build_status_lines_full: non-zero exit (old binary rejects --pi-health) omits the row" {
    local stub="$TMP/airplanes-webconfig-old"
    cat > "$stub" <<'EOF'
#!/bin/bash
# Mimic old binary: flag.Parse rejects unknown flag, exits 2.
echo "flag provided but not defined: -pi-health" >&2
exit 2
EOF
    chmod +x "$stub"
    export PATHS_PIHEALTH_BIN="$stub"
    collect_status_data live
    build_status_lines_full live
    ! find_hardware_row
}

# === Compact layout (narrow-terminal fallback under <80-col SSH MOTD) ===

@test "build_status_lines_compact: ok severity renders a Hardware row" {
    install_pihealth_stub $'ok\thealthy'
    collect_status_data snapshot
    build_status_lines_compact
    local row
    row="$(find_hardware_row)"
    [[ "$row" == *"Hardware"* ]]
    [[ "$row" == *"healthy"* ]]
}

@test "build_status_lines_compact: long summary is truncated, panel width respected" {
    local long_summary
    long_summary='undervolted now * throttling now * arm freq capped now * time not synced'
    install_pihealth_stub $'err\t'"$long_summary"
    collect_status_data snapshot
    build_status_lines_compact
    local row stripped
    row="$(find_hardware_row)"
    stripped="$row"  # already stripped by find_hardware_row
    # Hardware row in compact mode must fit STATUS_PANEL_WIDTH after ANSI
    # is stripped — verify the truncate kicked in.
    (( ${#stripped} <= STATUS_PANEL_WIDTH ))
    [[ "$stripped" == *"..." ]]
}

@test "build_status_lines_compact: missing binary omits the Hardware row" {
    collect_status_data snapshot
    build_status_lines_compact
    ! find_hardware_row
}

# === Snapshot builder (current SSH MOTD path under cols >= 80) ===

@test "build_status_lines_snapshot: ok severity renders a Hardware row" {
    install_pihealth_stub $'ok\thealthy'
    collect_status_data snapshot
    build_status_lines_snapshot
    local row
    row="$(find_hardware_row)"
    [[ "$row" == *"Hardware"* ]]
    [[ "$row" == *"healthy"* ]]
}

@test "build_status_lines_snapshot: long summary is truncated to fit 80 cols" {
    local long_summary
    long_summary='undervolted now * throttling now * arm freq capped now * time not synced * other-warn'
    install_pihealth_stub $'err\t'"$long_summary"
    collect_status_data snapshot
    build_status_lines_snapshot
    local row
    row="$(find_hardware_row)"
    # 12-cell label + truncated summary; the whole row must stay <= 80
    # cells so the banner-stack layout doesn't wrap.
    (( ${#row} <= 80 ))
    [[ "$row" == *"..." ]]
}

@test "build_status_lines_snapshot: missing binary omits the Hardware row" {
    collect_status_data snapshot
    build_status_lines_snapshot
    ! find_hardware_row
}

# === Absolute-path safety (MOTD scrubs /usr/local/bin from PATH) ===

@test "collect_status_data: scrubbed PATH does not prevent finding the binary" {
    # Simulate the MOTD wrapper: pin PATH to the system dirs, excluding
    # the directory where our stub lives. The Hardware row should still
    # render because PATHS_PIHEALTH_BIN is an absolute path.
    install_pihealth_stub $'ok\thealthy'
    PATH=/usr/sbin:/usr/bin:/sbin:/bin collect_status_data live
    build_status_lines_full live
    local row
    row="$(find_hardware_row)"
    [[ "$row" == *"healthy"* ]]
}
