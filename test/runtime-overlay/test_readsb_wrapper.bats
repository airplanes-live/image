#!/usr/bin/env bats

# Tests for runtime-overlay/src/share/airplanes/readsb.sh
# — the local 1090 MHz decoder wrapper. The wrapper composes a readsb argv
# from feed.env env vars (sourced by EnvironmentFile=-/etc/airplanes/feed.env
# in the systemd unit) plus hardcoded defaults, then execs /usr/bin/readsb.
#
# Test seam: READSB_BIN overrides the exec target. Production behavior is
# unchanged when READSB_BIN is unset.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../runtime-overlay/src/share/airplanes/readsb.sh"
    TMP="$(mktemp -d)"
    ARG_LOG="$TMP/readsb-args.log"

    # Stub readsb binary: writes each argv element on its own line, then
    # exits cleanly. One-arg-per-line is the canonical shape: tests can
    # `grep -Fxq` for a literal argv element to verify both presence AND
    # that it's a separate argv entry (not accidentally space-joined into
    # a neighbour by a quoting bug). `$@` not `$*` for that reason.
    READSB_BIN="$TMP/readsb-stub"
    cat > "$READSB_BIN" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$ARG_LOG"
exit 0
EOF
    chmod +x "$READSB_BIN"

    export READSB_BIN
    export ARG_LOG

    # Fake sysfs for the USB-serial probe; empty by default (no SDR present).
    SYS_USB="$TMP/sys-usb"
    mkdir -p "$SYS_USB"
    export READSB_USB_SERIAL_GLOB="$SYS_USB/*/serial"

    # Self-disable branch must not actually sleep in tests.
    export READSB_NO_HARDWARE_SLEEP=0

    # State file location + a minimal state-writer mock (the CI bats job checks
    # out only the image repo, not feed/). Mirrors the airplanes_write_state
    # contract from feed/scripts/lib/state-writer.sh: schema_version=1 first
    # line, KEY=VALUE in caller order, atomic via mktemp+rename.
    export READSB_RUNTIME_DIR="$TMP/run-readsb"
    mkdir -p "$READSB_RUNTIME_DIR"
    STATE_FILE="$READSB_RUNTIME_DIR/state"
    export STATE_WRITER_LIB="$TMP/state-writer.sh"
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
}

# Seed a fake USB device exposing the given serial so the probe finds it.
# Real sysfs serial files carry a trailing newline; the probe's command
# substitution strips it, so we write it the same way here.
seed_serial() {
    local serial="$1" dir
    dir="$(mktemp -d "$SYS_USB/dev.XXXXXX")"
    printf '%s\n' "$serial" > "$dir/serial"
}

# Helper: assert that two literal argv values appear adjacent in $ARG_LOG.
# Catches a quoting bug where the flag and its value got space-joined into
# one argv element. usage: assert_args_adjacent "--flag" "value"
assert_args_adjacent() {
    local flag="$1" value="$2"
    awk -v flag="$flag" -v value="$value" '
        $0 == flag { saw_flag = 1; next }
        saw_flag { if ($0 == value) { found = 1; exit } saw_flag = 0 }
        END { exit !found }
    ' "$ARG_LOG"
}

teardown() { rm -rf "$TMP"; }

# ---- Default invocation ----------------------------------------------------

@test "default invocation opens --net-bi-port 30004,30104 listener as separate argv entries" {
    # No env var set → wrapper's READSB_NET_OPTIONS default fires.
    # mlat-client routes --results beast,connect,127.0.0.1:30104 here so
    # MLAT planes appear locally (tar1090, graphs1090). 30004 is a courtesy
    # Beast input for co-resident processes. Assert the flag and value land
    # as adjacent argv entries — a quoting bug that space-joined them into
    # `--net-bi-port 30004,30104` (one argv element) would be silently
    # broken at runtime (readsb rejects glued flag/value pairs).
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$ARG_LOG" ]
    grep -Fxq -- '--net-bi-port' "$ARG_LOG"
    grep -Fxq -- '30004,30104' "$ARG_LOG"
    assert_args_adjacent '--net-bi-port' '30004,30104'
}

@test "default invocation preserves hardcoded output ports" {
    # Regression guard: a stale NET_OPTIONS (or any other env-var bag) must
    # never clobber the wrapper's hardcoded decoder ports.
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    assert_args_adjacent '--net-bo-port' '30005'
    assert_args_adjacent '--net-ri-port' '30001'
    assert_args_adjacent '--net-sbs-port' '30003'
    assert_args_adjacent '--net-api-port' '30152'
    assert_args_adjacent '--net-json-port' '30154'
}

@test "default invocation binds listeners to 127.0.0.1" {
    # Security regression guard: every listener (incl. the new MLAT-input
    # port) must remain loopback-only. The decoder is not a LAN-facing
    # service; an unbound 30004 would accept Beast input from any reachable
    # host.
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    assert_args_adjacent '--net-bind-address' '127.0.0.1'
}

# ---- READSB_NET_OPTIONS override -------------------------------------------

@test "READSB_NET_OPTIONS override is honoured" {
    # Operators can tune the decoder's net-listener bag via feed.env.
    READSB_NET_OPTIONS="--net-bi-port 30104" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    assert_args_adjacent '--net-bi-port' '30104'
    # The default 30004,30104 string must NOT appear when overridden — that
    # would mean the override is being ignored.
    if grep -Fxq -- '30004,30104' "$ARG_LOG"; then
        return 1
    fi
}

# ---- Operator can't defeat safety invariants -------------------------------

@test "READSB_NET_OPTIONS cannot override the loopback bind-address" {
    # Defense in depth: even if an operator (or a bad migration) sets
    # READSB_NET_OPTIONS="--net-bind-address 0.0.0.0", the hardcoded
    # --net-bind-address 127.0.0.1 must win. readsb's argp parser is
    # last-wins for repeated options, so the hardcoded value must appear
    # AFTER READSB_NET_OPTIONS in the argv. This test pins that ordering.
    READSB_NET_OPTIONS="--net-bind-address 0.0.0.0" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # The hardcoded loopback bind must appear AFTER the override. Walk the
    # arg log: the LAST --net-bind-address line should be followed by
    # 127.0.0.1, not 0.0.0.0.
    last_bind=$(awk '$0 == "--net-bind-address" { found = NR } END { print found }' "$ARG_LOG")
    [ -n "$last_bind" ]
    bind_value=$(sed -n "$((last_bind + 1))p" "$ARG_LOG")
    [ "$bind_value" = "127.0.0.1" ]
}

@test "READSB_NET_OPTIONS containing a literal * does NOT glob-expand against CWD" {
    # The wrapper uses `read -ra` to split READSB_NET_OPTIONS instead of
    # unquoted parameter expansion, so shell globbing must not fire even
    # when the operator passes a literal asterisk. CWD-dependent expansion
    # would otherwise leak filenames from the service working directory
    # into the readsb argv.
    cd "$TMP"  # CWD with deterministic contents (just the stub binary)
    READSB_NET_OPTIONS="--net-connector 127.0.0.1,*,beast_in" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # Literal * survives (not expanded to "readsb-stub" or any filename).
    grep -Fxq -- '--net-connector' "$ARG_LOG"
    grep -Fxq -- '127.0.0.1,*,beast_in' "$ARG_LOG"
}

# ---- SDR device selection (READSB_SDR_SERIAL) ------------------------------

@test "no READSB_SDR_SERIAL means no --device flag (single-SDR default)" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    if grep -Fxq -- '--device' "$ARG_LOG"; then
        return 1
    fi
    # The SDR is still claimed via the default rtlsdr path.
    assert_args_adjacent '--device-type' 'rtlsdr'
}

@test "READSB_SDR_SERIAL pins exactly one --device" {
    seed_serial 1090
    READSB_SDR_SERIAL=1090 run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -cFx -- '--device' "$ARG_LOG")" = "1" ]
    assert_args_adjacent '--device' '1090'
    assert_args_adjacent '--device-type' 'rtlsdr'
}

@test "stale legacy RECEIVER_OPTIONS cannot inject a second --device" {
    # Legacy /boot/airplanes-env carried RECEIVER_OPTIONS with its own
    # --device pin. The wrapper deliberately never reads that bag; if it
    # ever started to, a migrated feeder could end up with two conflicting
    # --device args (last-wins would silently override the operator's
    # webconfig choice).
    seed_serial 1090
    RECEIVER_OPTIONS="--device 00000001 --device-type rtlsdr --ppm 0" \
        READSB_SDR_SERIAL=1090 run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -cFx -- '--device' "$ARG_LOG")" = "1" ]
    assert_args_adjacent '--device' '1090'
    # Nothing else from RECEIVER_OPTIONS may bleed in either.
    if grep -Fxq -- '--ppm' "$ARG_LOG"; then
        return 1
    fi
}

@test "DUMP1090=no (net-only) ignores READSB_SDR_SERIAL" {
    DUMP1090=no READSB_SDR_SERIAL=1090 run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -Fxq -- '--net-only' "$ARG_LOG"
    if grep -Fxq -- '--device' "$ARG_LOG"; then
        return 1
    fi
}

# ---- Pinned-SDR-absent self-disable (the hardware gate) --------------------

@test "pinned SDR absent self-disables: no exec, exit 0, state no_hardware" {
    # No matching serial seeded → probe fails → the wrapper publishes the
    # decision, sleeps (0 in tests), and exits 0 instead of exec'ing readsb
    # into a 15s restart loop.
    READSB_SDR_SERIAL=1090 run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$ARG_LOG" ]                  # readsb was never exec'd
    grep -Fxq 'service=readsb'     "$STATE_FILE"
    grep -Fxq 'state=disabled'     "$STATE_FILE"
    grep -Fxq 'reason=no_hardware' "$STATE_FILE"
    grep -Fxq 'sdr_serial=1090'    "$STATE_FILE"
}

@test "pinned SDR present execs readsb and publishes enabled/ok" {
    seed_serial 1090
    READSB_SDR_SERIAL=1090 run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$ARG_LOG" ]
    assert_args_adjacent '--device' '1090'
    grep -Fxq 'state=enabled' "$STATE_FILE"
    grep -Fxq 'reason=ok'     "$STATE_FILE"
}

@test "no pin: no probe, execs, publishes enabled/ok (single-SDR untouched)" {
    # Empty SYS_USB + no pin → the probe must not run; the decoder starts
    # exactly as before and reports enabled/ok.
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$ARG_LOG" ]
    if grep -Fxq -- '--device' "$ARG_LOG"; then return 1; fi
    grep -Fxq 'state=enabled' "$STATE_FILE"
    grep -Fxq 'reason=ok'     "$STATE_FILE"
}

@test "DUMP1090=no skips the probe and never self-disables on an absent pin" {
    # Net-only mode does not touch the SDR, so a pinned-but-absent serial must
    # NOT self-disable it — it execs --net-only and reports enabled/ok.
    DUMP1090=no READSB_SDR_SERIAL=1090 run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$ARG_LOG" ]
    grep -Fxq -- '--net-only' "$ARG_LOG"
    grep -Fxq 'state=enabled' "$STATE_FILE"
    grep -Fxq 'reason=ok'     "$STATE_FILE"
}

@test "probe finds the pinned serial among multiple devices" {
    seed_serial 00000001
    seed_serial 1090
    seed_serial 00000978
    READSB_SDR_SERIAL=1090 run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$ARG_LOG" ]
    assert_args_adjacent '--device' '1090'
}

@test "a pin matching none of several present devices self-disables" {
    seed_serial 00000001
    seed_serial 00000978
    READSB_SDR_SERIAL=1090 run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$ARG_LOG" ]
    grep -Fxq 'reason=no_hardware' "$STATE_FILE"
}

@test "empty serial files are skipped without aborting the probe" {
    # An empty /sys/.../serial must not trip set -e before the real match.
    local d; d="$(mktemp -d "$SYS_USB/dev.XXXXXX")"; : > "$d/serial"
    seed_serial 1090
    READSB_SDR_SERIAL=1090 run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$ARG_LOG" ]
    assert_args_adjacent '--device' '1090'
}

@test "no USB devices at all (empty glob) self-disables cleanly" {
    # SYS_USB empty → the glob matches nothing; the for-loop must not abort
    # under set -e, and the wrapper must self-disable rather than exec.
    READSB_SDR_SERIAL=00000001 run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$ARG_LOG" ]
    grep -Fxq 'reason=no_hardware' "$STATE_FILE"
}

# ---- Stale-NET_OPTIONS regression -----------------------------------------

@test "stale legacy NET_OPTIONS does NOT bleed into the decoder argv" {
    # Legacy /etc/default/airplanes carried a feeder-tuned NET_OPTIONS like
    # "--net-bo-port 0 --net-ri-port 0 --net-sbs-port 0 ..." to suppress the
    # combined binary's output ports. If migrated unchanged into feed.env,
    # that string MUST NOT reach this decoder — it would silently kill the
    # 30005 / 30001 / 30003 listeners that tar1090, mlat-client, and the
    # outbound feeder all depend on.
    NET_OPTIONS="--net-bo-port 0 --net-ri-port 0 --net-sbs-port 0" \
        run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # Hardcoded ports must survive as adjacent argv pairs.
    assert_args_adjacent '--net-bo-port' '30005'
    assert_args_adjacent '--net-ri-port' '30001'
    assert_args_adjacent '--net-sbs-port' '30003'
    # NET_OPTIONS must not reach argv at all: each port flag appears
    # exactly once (the hardcoded one). If the stale NET_OPTIONS were
    # bleeding in, --net-bo-port / --net-ri-port / --net-sbs-port would
    # each appear twice (once with our value, once with 0).
    [ "$(grep -cFx -- '--net-bo-port' "$ARG_LOG")" = "1" ]
    [ "$(grep -cFx -- '--net-ri-port' "$ARG_LOG")" = "1" ]
    [ "$(grep -cFx -- '--net-sbs-port' "$ARG_LOG")" = "1" ]
}
