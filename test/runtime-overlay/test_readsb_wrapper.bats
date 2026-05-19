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
