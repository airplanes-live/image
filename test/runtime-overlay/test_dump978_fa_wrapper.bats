#!/usr/bin/env bats

# Tests for dump978-fa.sh — the 978 producer wrapper. The wrapper reads
# UAT_INPUT + DUMP978_SDR_SERIAL from the EnvironmentFile-loaded env,
# runs a /sys/bus/usb/devices/*/serial probe to confirm an SDR with the
# requested serial is present, and either execs dump978-fa, sleeps for
# the disabled branches (uat_disabled / no_hardware → exit 0, unit stays
# active), or exits 64 for misconfigured UAT_INPUT.
#
# Test hooks consumed:
#   DUMP978_FA_BIN                  — binary stub (avoids real /usr/bin/dump978-fa)
#   DUMP978_FA_RUNTIME_DIR          — state file directory (TMP-rooted)
#   DUMP978_FA_USB_SERIAL_GLOB      — probe glob (TMP-rooted; tests place
#                                     matching/missing serial files there)
#   STATE_WRITER_LIB                — points at the inline mock below
#   DUMP978_FA_DISABLED_SLEEP=0     — bypass the uat_disabled sleep
#   DUMP978_FA_NO_HARDWARE_SLEEP=0  — bypass the no_hardware sleep

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../runtime-overlay/src/share/airplanes/dump978-fa.sh"
    TMP="$(mktemp -d)"

    # Inline minimal airplanes_write_state. Same shape as the feed-shipped
    # state-writer.sh (schema_version=1 first, KEY=VALUE in caller order,
    # 0644, atomic via mktemp+rename). See test_airplanes_978_wrapper.bats
    # for the rationale on inlining.
    STATE_WRITER_LIB="$TMP/state-writer.sh"
    cat > "$STATE_WRITER_LIB" <<'WRITER'
airplanes_write_state() {
    local target="$1"; shift
    local kv key value tmp
    tmp="$(mktemp "${target}.XXXXXX")" || return 1
    {
        printf 'schema_version=1\n'
        for kv in "$@"; do
            key="${kv%%=*}"
            value="${kv#*=}"
            printf '%s=%s\n' "$key" "$value"
        done
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$target"
}
WRITER

    DUMP978_FA_RUNTIME_DIR="$TMP/run-dump978-fa"
    mkdir -p "$DUMP978_FA_RUNTIME_DIR"

    # USB probe surface: a directory tree the wrapper can glob over for
    # `*/serial` files. Tests fill or empty this to simulate dongle
    # presence/absence.
    USB_ROOT="$TMP/usb-devices"
    mkdir -p "$USB_ROOT"
    DUMP978_FA_USB_SERIAL_GLOB="$USB_ROOT/*/serial"

    # Stub the binary: writes its argv and exits 0.
    DUMP978_FA_BIN="$TMP/dump978-fa-bin"
    cat > "$DUMP978_FA_BIN" <<EOF
#!/bin/bash
echo "executed: \$*" > "$TMP/binary-invoked"
exit 0
EOF
    chmod +x "$DUMP978_FA_BIN"

    # Bypass the disabled-state sleeps so the wrapper returns promptly.
    # Production defaults are 3600/60s; 0 is test-only (in production it
    # would create a restart storm under Restart=always).
    DUMP978_FA_DISABLED_SLEEP=0
    DUMP978_FA_NO_HARDWARE_SLEEP=0

    export STATE_WRITER_LIB DUMP978_FA_RUNTIME_DIR DUMP978_FA_USB_SERIAL_GLOB DUMP978_FA_BIN \
        DUMP978_FA_DISABLED_SLEEP DUMP978_FA_NO_HARDWARE_SLEEP
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

# Drop a serial file at the given path. Helper for "this SDR is present".
plug_sdr() {
    local serial="$1" devname="${2:-usb1-dev0}"
    mkdir -p "$USB_ROOT/$devname"
    printf '%s' "$serial" > "$USB_ROOT/$devname/serial"
}

# ---- UAT_INPUT="" → state=disabled reason=uat_disabled, sleep + exit 0 ---

@test "01: UAT_INPUT empty → state=disabled reason=uat_disabled, exit 0" {
    run_wrapper ""
    [ "$status" -eq 0 ]
    [ -f "$DUMP978_FA_RUNTIME_DIR/state" ]
    grep -Fxq 'state=disabled' "$DUMP978_FA_RUNTIME_DIR/state"
    grep -Fxq 'reason=uat_disabled' "$DUMP978_FA_RUNTIME_DIR/state"
    [ ! -e "$TMP/binary-invoked" ]
}

@test "02: UAT_INPUT unset → treated as empty (state=disabled)" {
    # env -u to distinguish "" from absent.
    run env -u UAT_INPUT \
        STATE_WRITER_LIB="$STATE_WRITER_LIB" \
        DUMP978_FA_RUNTIME_DIR="$DUMP978_FA_RUNTIME_DIR" \
        DUMP978_FA_USB_SERIAL_GLOB="$DUMP978_FA_USB_SERIAL_GLOB" \
        DUMP978_FA_BIN="$DUMP978_FA_BIN" \
        DUMP978_FA_DISABLED_SLEEP=0 \
        DUMP978_FA_NO_HARDWARE_SLEEP=0 \
        bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -Fxq 'state=disabled' "$DUMP978_FA_RUNTIME_DIR/state"
    grep -Fxq 'reason=uat_disabled' "$DUMP978_FA_RUNTIME_DIR/state"
}

# ---- UAT_INPUT valid + probe MISS → state=disabled reason=no_hardware ----

@test "03: UAT_INPUT valid + no SDR with matching serial → state=disabled reason=no_hardware, exit 0" {
    # USB_ROOT is empty (no */serial files). Probe miss.
    run_wrapper "127.0.0.1:30978"
    [ "$status" -eq 0 ]
    grep -Fxq 'state=disabled' "$DUMP978_FA_RUNTIME_DIR/state"
    grep -Fxq 'reason=no_hardware' "$DUMP978_FA_RUNTIME_DIR/state"
    [ ! -e "$TMP/binary-invoked" ]
}

@test "04: probe miss → state file records sdr_serial=978 (the requested serial)" {
    run_wrapper "127.0.0.1:30978"
    grep -Fxq 'sdr_serial=978' "$DUMP978_FA_RUNTIME_DIR/state"
}

@test "05: probe ignores devices with different serials (e.g. 1090)" {
    # Plug the 1090 dongle but not the 978 one — wrapper should still
    # report no_hardware because the requested serial is "978".
    plug_sdr "1090" "usb1-1.1"
    run_wrapper "127.0.0.1:30978"
    [ "$status" -eq 0 ]
    grep -Fxq 'reason=no_hardware' "$DUMP978_FA_RUNTIME_DIR/state"
}

# ---- UAT_INPUT valid + probe HIT → state=enabled, exec binary -----------

@test "06: UAT_INPUT valid + SDR with serial=978 present → state=enabled reason=ok, binary invoked" {
    plug_sdr "978" "usb1-1.4"
    run_wrapper "127.0.0.1:30978"
    [ "$status" -eq 0 ]
    grep -Fxq 'state=enabled' "$DUMP978_FA_RUNTIME_DIR/state"
    grep -Fxq 'reason=ok' "$DUMP978_FA_RUNTIME_DIR/state"
    [ -e "$TMP/binary-invoked" ]
}

@test "07: probe hit → binary receives sdr + raw-port + json-port args" {
    plug_sdr "978" "usb1-1.4"
    run_wrapper "127.0.0.1:30978"
    grep -q 'driver=rtlsdr,serial=978' "$TMP/binary-invoked"
    grep -q 'raw-port 127.0.0.1:30978' "$TMP/binary-invoked"
    grep -q 'json-port 127.0.0.1:30979' "$TMP/binary-invoked"
}

@test "08: probe hits the FIRST matching serial when multiple devices present" {
    plug_sdr "1090" "usb1-1.1"
    plug_sdr "978"  "usb1-1.2"
    plug_sdr "other" "usb1-1.3"
    run_wrapper "127.0.0.1:30978"
    [ "$status" -eq 0 ]
    grep -Fxq 'reason=ok' "$DUMP978_FA_RUNTIME_DIR/state"
}

@test "09: probe is non-mutating — serial files are not modified" {
    plug_sdr "978" "usb1-1.4"
    local before
    before="$(cat "$USB_ROOT/usb1-1.4/serial")"
    run_wrapper "127.0.0.1:30978"
    [ "$(cat "$USB_ROOT/usb1-1.4/serial")" = "$before" ]
}

# ---- DUMP978_SDR_SERIAL override -----------------------------------------

@test "10: custom DUMP978_SDR_SERIAL is what the probe looks for" {
    plug_sdr "my-custom-serial" "usb2-2.1"
    DUMP978_SDR_SERIAL="my-custom-serial" UAT_INPUT="127.0.0.1:30978" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -Fxq 'reason=ok' "$DUMP978_FA_RUNTIME_DIR/state"
    grep -q 'driver=rtlsdr,serial=my-custom-serial' "$TMP/binary-invoked"
}

@test "11: custom DUMP978_SDR_SERIAL with no matching device → no_hardware" {
    plug_sdr "978" "usb2-2.1"
    DUMP978_SDR_SERIAL="something-else" UAT_INPUT="127.0.0.1:30978" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -Fxq 'reason=no_hardware' "$DUMP978_FA_RUNTIME_DIR/state"
    grep -Fxq 'sdr_serial=something-else' "$DUMP978_FA_RUNTIME_DIR/state"
}

# ---- Invalid UAT_INPUT → misconfigured -----------------------------------

@test "12: UAT_INPUT=10.0.0.5:30978 → state=misconfigured reason=uat_input_invalid" {
    plug_sdr "978" "usb1-1.4"  # SDR present, but UAT_INPUT is still invalid
    run_wrapper "10.0.0.5:30978"
    [ "$status" -eq 64 ]
    grep -Fxq 'state=misconfigured' "$DUMP978_FA_RUNTIME_DIR/state"
    grep -Fxq 'reason=uat_input_invalid' "$DUMP978_FA_RUNTIME_DIR/state"
    [ ! -e "$TMP/binary-invoked" ]
}

@test "13: UAT_INPUT with shell metachars → state=misconfigured (no shell injection)" {
    run_wrapper "evil-host;rm -rf /"
    [ "$status" -eq 64 ]
    grep -Fxq 'state=misconfigured' "$DUMP978_FA_RUNTIME_DIR/state"
    [ ! -e "$TMP/binary-invoked" ]
}

# ---- State-file shape ----------------------------------------------------

@test "14: state file first line is schema_version=1" {
    run_wrapper ""
    head -n1 "$DUMP978_FA_RUNTIME_DIR/state" | grep -Fxq 'schema_version=1'
}

@test "15: state file mode is 0644" {
    run_wrapper ""
    local mode
    mode="$(stat -c '%a' "$DUMP978_FA_RUNTIME_DIR/state" 2>/dev/null || stat -f '%A' "$DUMP978_FA_RUNTIME_DIR/state")"
    [ "$mode" = "644" ]
}

@test "16: state file is rewritten on every invocation (no_hardware → ok after plug-in)" {
    run_wrapper "127.0.0.1:30978"
    grep -Fxq 'reason=no_hardware' "$DUMP978_FA_RUNTIME_DIR/state"
    plug_sdr "978" "usb1-1.4"
    run_wrapper "127.0.0.1:30978"
    grep -Fxq 'reason=ok' "$DUMP978_FA_RUNTIME_DIR/state"
    # And no leftover reason=no_hardware lurking in the file:
    ! grep -Fxq 'reason=no_hardware' "$DUMP978_FA_RUNTIME_DIR/state"
}

# ---- Defensive: missing state-writer lib --------------------------------

@test "17: missing state-writer lib → wrapper still self-disables on no_hardware" {
    # State file won't be written (no writer) but wrapper must still skip
    # the daemon exec — sleeping out the no_hardware branch is preferable
    # to spawning dump978-fa into a no-SDR failure loop.
    STATE_WRITER_LIB="/nonexistent/state-writer.sh" run_wrapper "127.0.0.1:30978"
    [ "$status" -eq 0 ]
    [ ! -e "$DUMP978_FA_RUNTIME_DIR/state" ]
    [ ! -e "$TMP/binary-invoked" ]
}

@test "18: missing state-writer lib + probe hit → wrapper still exec's binary" {
    plug_sdr "978" "usb1-1.4"
    STATE_WRITER_LIB="/nonexistent/state-writer.sh" run_wrapper "127.0.0.1:30978"
    [ "$status" -eq 0 ]
    [ ! -e "$DUMP978_FA_RUNTIME_DIR/state" ]
    [ -e "$TMP/binary-invoked" ]
}
