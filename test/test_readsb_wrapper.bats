#!/usr/bin/env bats

# Tests for stage-airplanes/02-install-decoder/files/usr/local/share/airplanes/readsb.sh
# — the local 1090 MHz decoder wrapper. The wrapper composes a readsb argv
# from feed.env env vars (sourced by EnvironmentFile=-/etc/airplanes/feed.env
# in the systemd unit) plus hardcoded defaults, then execs /usr/bin/readsb.
#
# Test seam: READSB_BIN overrides the exec target. Production behavior is
# unchanged when READSB_BIN is unset.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/02-install-decoder/files/usr/local/share/airplanes/readsb.sh"
    TMP="$(mktemp -d)"
    ARG_LOG="$TMP/readsb-args.log"

    # Stub readsb binary: writes argv to a log and exits cleanly. This is
    # the only way to intercept the wrapper's `exec` without touching the
    # real /usr/bin/readsb on CI/dev hosts.
    READSB_BIN="$TMP/readsb-stub"
    cat > "$READSB_BIN" <<EOF
#!/bin/bash
printf '%s\n' "\$*" > "$ARG_LOG"
exit 0
EOF
    chmod +x "$READSB_BIN"

    export READSB_BIN
    export ARG_LOG
}

teardown() { rm -rf "$TMP"; }

# ---- Default invocation ----------------------------------------------------

@test "default invocation opens --net-bi-port 30004,30104 listener" {
    # No env var set → wrapper's READSB_NET_OPTIONS default fires.
    # mlat-client routes --results beast,connect,127.0.0.1:30104 here so
    # MLAT planes appear locally (tar1090, graphs1090). 30004 is a courtesy
    # Beast input for co-resident processes.
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$ARG_LOG" ]
    grep -q -- '--net-bi-port 30004,30104' "$ARG_LOG"
}

@test "default invocation preserves hardcoded output ports" {
    # Regression guard: a stale NET_OPTIONS (or any other env-var bag) must
    # never clobber the wrapper's hardcoded decoder ports.
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q -- '--net-bo-port 30005' "$ARG_LOG"
    grep -q -- '--net-ri-port 30001' "$ARG_LOG"
    grep -q -- '--net-sbs-port 30003' "$ARG_LOG"
    grep -q -- '--net-api-port 30152' "$ARG_LOG"
    grep -q -- '--net-json-port 30154' "$ARG_LOG"
}

@test "default invocation binds listeners to 127.0.0.1" {
    # Security regression guard: every listener (incl. the new MLAT-input
    # port) must remain loopback-only. The decoder is not a LAN-facing
    # service; an unbound 30004 would accept Beast input from any reachable
    # host.
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q -- '--net-bind-address 127.0.0.1' "$ARG_LOG"
}

# ---- READSB_NET_OPTIONS override -------------------------------------------

@test "READSB_NET_OPTIONS override is honoured" {
    # Operators can tune the decoder's net-listener bag via feed.env.
    READSB_NET_OPTIONS="--net-bi-port 30104" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q -- '--net-bi-port 30104' "$ARG_LOG"
    # The default 30004,30104 string must NOT appear when overridden — that
    # would mean the override is being ignored.
    if grep -q -- '--net-bi-port 30004,30104' "$ARG_LOG"; then
        return 1
    fi
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
    # Hardcoded ports must survive.
    grep -q -- '--net-bo-port 30005' "$ARG_LOG"
    grep -q -- '--net-ri-port 30001' "$ARG_LOG"
    grep -q -- '--net-sbs-port 30003' "$ARG_LOG"
    # The "port 0" suppression strings must NOT appear in the readsb argv.
    if grep -q -- '--net-bo-port 0' "$ARG_LOG"; then
        return 1
    fi
    if grep -q -- '--net-ri-port 0' "$ARG_LOG"; then
        return 1
    fi
    if grep -q -- '--net-sbs-port 0' "$ARG_LOG"; then
        return 1
    fi
}
