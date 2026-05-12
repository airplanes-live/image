#!/usr/bin/env bats

# Tests for airplanes-978.sh — the UAT relay wrapper. The wrapper reads
# UAT_INPUT from the EnvironmentFile-loaded env, classifies into
# enabled / disabled / misconfigured, writes /run/airplanes-978/state via
# state-writer.sh, and either execs the daemon, sleeps (uat_disabled →
# exit 0, unit stays active), or exits 64 (misconfigured input).
#
# Test hooks consumed:
#   AIRPLANES_978_RUNTIME_DIR    — state file path + cleanup target
#   AIRPLANES_978_BIN            — binary stub (avoids real /usr/bin/airplanes-978)
#   STATE_WRITER_LIB             — points at the source-tree state-writer.sh
#   AIRPLANES_978_DISABLED_SLEEP — set to 0 by setup() so the wrapper
#                                  returns promptly from the disabled branch

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/02-install-decoder/files/usr/local/share/airplanes/airplanes-978.sh"
    TMP="$(mktemp -d)"

    # CI bats job only checks out the image repo, not feed/. Inline a
    # minimal airplanes_write_state mirroring the contract from
    # feed/scripts/lib/state-writer.sh: schema_version=1 first line, KEY=VALUE
    # in caller order, 0644 mode, atomic via mktemp+rename. The full feed
    # implementation also validates keys + rejects CR/LF; the wrapper only
    # supplies safe values, so the mock skips that for test self-containment.
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

    # State reader stub mirroring feed/scripts/lib/state-reader.sh's
    # airplanes_read_state. Reads schema_version=1, returns the value
    # for the requested key on stdout, rc 0 on hit / rc 1 on miss.
    STATE_READER_LIB="$TMP/state-reader.sh"
    cat > "$STATE_READER_LIB" <<'READER'
airplanes_read_state() {
    local file="$1" key="$2"
    [[ -f "$file" && -r "$file" ]] || return 1
    local first=1 line value
    while IFS= read -r line; do
        if (( first )); then
            first=0
            [[ "$line" == 'schema_version=1' ]] || return 1
            continue
        fi
        case "$line" in
            "${key}="*)
                value="${line#"${key}="}"
                printf '%s' "$value"
                return 0
                ;;
        esac
    done < "$file"
    return 1
}
READER

    AIRPLANES_978_RUNTIME_DIR="$TMP/run-airplanes-978"
    mkdir -p "$AIRPLANES_978_RUNTIME_DIR"

    # Peer state file (dump978-fa's publication). Default: non-existent
    # so the wrapper falls through to plain reason=ok. Tests that exercise
    # the peer_no_hardware refinement create this file with the right
    # contents.
    DUMP978_FA_STATE_FILE="$TMP/run-dump978-fa/state"

    # Stub the binary: writes its argv to a marker file and exits 0.
    AIRPLANES_978_BIN="$TMP/airplanes-978-bin"
    cat > "$AIRPLANES_978_BIN" <<EOF
#!/bin/bash
echo "executed: \$*" > "$TMP/binary-invoked"
exit 0
EOF
    chmod +x "$AIRPLANES_978_BIN"

    # Bypass the uat_disabled sleep so the wrapper returns promptly. 0 is
    # test-only; in production it would create a restart storm under
    # Restart=always.
    AIRPLANES_978_DISABLED_SLEEP=0

    export AIRPLANES_978_RUNTIME_DIR
    export AIRPLANES_978_BIN
    export STATE_WRITER_LIB
    export STATE_READER_LIB
    export DUMP978_FA_STATE_FILE
    export AIRPLANES_978_DISABLED_SLEEP
}

# Helper: write a peer state file with the given state/reason. Used to
# simulate dump978-fa's publication for the peer_no_hardware refinement.
write_peer_state() {
    local state="$1" reason="$2"
    mkdir -p "$(dirname "$DUMP978_FA_STATE_FILE")"
    {
        printf 'schema_version=1\n'
        printf 'service=dump978-fa\n'
        printf 'state=%s\n' "$state"
        printf 'reason=%s\n' "$reason"
    } > "$DUMP978_FA_STATE_FILE"
}

teardown() { rm -rf "$TMP"; }

# Run the wrapper with an explicit UAT_INPUT value. The wrapper has `set -e`,
# so we use `bash` (not source) to capture exit code without affecting bats.
run_wrapper() {
    local uat="$1"
    if [[ -n "$uat" ]]; then
        UAT_INPUT="$uat" run bash "$SCRIPT"
    else
        UAT_INPUT="" run bash "$SCRIPT"
    fi
}

# ---- UAT_INPUT="" → state=disabled, sleep + exit 0 -----------------------

@test "01: UAT_INPUT empty → state=disabled reason=uat_disabled, exit 0" {
    run_wrapper ""
    [ "$status" -eq 0 ]
    [ -f "$AIRPLANES_978_RUNTIME_DIR/state" ]
    grep -Fxq 'schema_version=1' "$AIRPLANES_978_RUNTIME_DIR/state"
    grep -Fxq 'state=disabled' "$AIRPLANES_978_RUNTIME_DIR/state"
    grep -Fxq 'reason=uat_disabled' "$AIRPLANES_978_RUNTIME_DIR/state"
}

@test "02: UAT_INPUT empty → binary not invoked" {
    run_wrapper ""
    [ ! -e "$TMP/binary-invoked" ]
}

@test "03: UAT_INPUT unset → treated as empty (state=disabled)" {
    # Use env -u to actually unset the var, distinguishing "" from absent.
    run env -u UAT_INPUT bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -Fxq 'state=disabled' "$AIRPLANES_978_RUNTIME_DIR/state"
}

# ---- UAT_INPUT="127.0.0.1:30978" → enabled --------------------------------

@test "04: UAT_INPUT=127.0.0.1:30978 → state=enabled reason=ok" {
    run_wrapper "127.0.0.1:30978"
    [ "$status" -eq 0 ]
    [ -f "$AIRPLANES_978_RUNTIME_DIR/state" ]
    grep -Fxq 'state=enabled' "$AIRPLANES_978_RUNTIME_DIR/state"
    grep -Fxq 'reason=ok' "$AIRPLANES_978_RUNTIME_DIR/state"
}

@test "05: UAT_INPUT enabled → binary IS invoked" {
    run_wrapper "127.0.0.1:30978"
    [ -e "$TMP/binary-invoked" ]
}

@test "06: UAT_INPUT enabled → binary receives net-connector + write-json args" {
    run_wrapper "127.0.0.1:30978"
    grep -q 'net-connector 127.0.0.1,30978,uat_in,silent_fail' "$TMP/binary-invoked"
    grep -q "write-json $AIRPLANES_978_RUNTIME_DIR" "$TMP/binary-invoked"
}

# ---- Invalid UAT_INPUT → misconfigured -----------------------------------

@test "07: UAT_INPUT=10.0.0.5:30978 → state=misconfigured reason=uat_input_invalid" {
    run_wrapper "10.0.0.5:30978"
    [ "$status" -eq 64 ]
    [ -f "$AIRPLANES_978_RUNTIME_DIR/state" ]
    grep -Fxq 'state=misconfigured' "$AIRPLANES_978_RUNTIME_DIR/state"
    grep -Fxq 'reason=uat_input_invalid' "$AIRPLANES_978_RUNTIME_DIR/state"
}

@test "08: invalid UAT_INPUT → binary not invoked" {
    run_wrapper "10.0.0.5:30978"
    [ ! -e "$TMP/binary-invoked" ]
}

@test "09: UAT_INPUT with shell metachars → state=misconfigured (no shell injection)" {
    # The wrapper's classifier uses bash case which is structural; metachars
    # never reach the binary.
    run_wrapper "evil-host;rm -rf /"
    [ "$status" -eq 64 ]
    grep -Fxq 'state=misconfigured' "$AIRPLANES_978_RUNTIME_DIR/state"
    [ ! -e "$TMP/binary-invoked" ]
}

@test "10: UAT_INPUT with leading/trailing whitespace → state=misconfigured" {
    # The classifier does literal-string matching; "127.0.0.1:30978 " (trailing
    # space) is NOT the canonical form and is rejected as misconfigured.
    run_wrapper " 127.0.0.1:30978"
    [ "$status" -eq 64 ]
    grep -Fxq 'state=misconfigured' "$AIRPLANES_978_RUNTIME_DIR/state"
}

# ---- aircraft.json cleanup on disable ------------------------------------

@test "11: stale aircraft.json is removed before state write" {
    # Simulate a previous enabled-run that left aircraft.json behind.
    : > "$AIRPLANES_978_RUNTIME_DIR/aircraft.json"
    : > "$AIRPLANES_978_RUNTIME_DIR/receiver.json"
    : > "$AIRPLANES_978_RUNTIME_DIR/stats.json"

    run_wrapper ""
    [ "$status" -eq 0 ]
    [ ! -e "$AIRPLANES_978_RUNTIME_DIR/aircraft.json" ]
    [ ! -e "$AIRPLANES_978_RUNTIME_DIR/receiver.json" ]
    [ ! -e "$AIRPLANES_978_RUNTIME_DIR/stats.json" ]
}

@test "12: state file survives the cleanup (state is not *.json)" {
    : > "$AIRPLANES_978_RUNTIME_DIR/aircraft.json"

    run_wrapper ""
    [ "$status" -eq 0 ]
    [ -f "$AIRPLANES_978_RUNTIME_DIR/state" ]
    [ ! -e "$AIRPLANES_978_RUNTIME_DIR/aircraft.json" ]
}

# ---- State file content --------------------------------------------------

@test "13: state file contains decided_at + uat_input fields" {
    run_wrapper "127.0.0.1:30978"
    grep -q '^decided_at=' "$AIRPLANES_978_RUNTIME_DIR/state"
    grep -Fxq 'uat_input=127.0.0.1:30978' "$AIRPLANES_978_RUNTIME_DIR/state"
}

@test "14: state file mode is 0644" {
    run_wrapper ""
    local mode
    mode="$(stat -c '%a' "$AIRPLANES_978_RUNTIME_DIR/state" 2>/dev/null || stat -f '%A' "$AIRPLANES_978_RUNTIME_DIR/state")"
    [ "$mode" = "644" ]
}

@test "15: state file first line is schema_version=1" {
    run_wrapper "127.0.0.1:30978"
    head -n1 "$AIRPLANES_978_RUNTIME_DIR/state" | grep -Fxq 'schema_version=1'
}

# ---- Defensive: missing state-writer lib ---------------------------------

@test "16: missing state-writer lib → wrapper still self-disables (defensive)" {
    STATE_WRITER_LIB="/nonexistent/state-writer.sh" run_wrapper ""
    [ "$status" -eq 0 ]
    # State file is NOT written (no library to write it), but the wrapper
    # correctly skips the daemon exec and sleeps out the disabled branch —
    # degrades to systemd-only rendering, which is the documented fallback.
    [ ! -e "$AIRPLANES_978_RUNTIME_DIR/state" ]
}

# ---- peer_no_hardware refinement -----------------------------------------

@test "17: enabled + peer state=disabled reason=no_hardware → reason=peer_no_hardware" {
    write_peer_state disabled no_hardware
    run_wrapper "127.0.0.1:30978"
    [ "$status" -eq 0 ]
    grep -Fxq 'state=enabled' "$AIRPLANES_978_RUNTIME_DIR/state"
    grep -Fxq 'reason=peer_no_hardware' "$AIRPLANES_978_RUNTIME_DIR/state"
    # And the binary still runs — silent_fail on the connector is the
    # safety net for the idle-relay case.
    [ -e "$TMP/binary-invoked" ]
}

@test "18: enabled + peer state=enabled reason=ok → reason stays ok" {
    write_peer_state enabled ok
    run_wrapper "127.0.0.1:30978"
    [ "$status" -eq 0 ]
    grep -Fxq 'reason=ok' "$AIRPLANES_978_RUNTIME_DIR/state"
    # peer_no_hardware should NOT appear when the peer is healthy.
    ! grep -Fxq 'reason=peer_no_hardware' "$AIRPLANES_978_RUNTIME_DIR/state"
}

@test "19: enabled + peer state=disabled reason=uat_disabled → reason stays ok (only no_hardware refines)" {
    # When the user disables UAT the peer also writes state=disabled but
    # reason=uat_disabled. Our wrapper should only refine on no_hardware,
    # not on every disabled reason.
    write_peer_state disabled uat_disabled
    run_wrapper "127.0.0.1:30978"
    grep -Fxq 'reason=ok' "$AIRPLANES_978_RUNTIME_DIR/state"
}

@test "20: enabled + no peer state file → reason stays ok (no refinement)" {
    # Defensive: the wrapper must not fail when the peer hasn't written
    # its state file yet (cold-boot race, or pre-image-PR build).
    rm -f "$DUMP978_FA_STATE_FILE"
    run_wrapper "127.0.0.1:30978"
    [ "$status" -eq 0 ]
    grep -Fxq 'reason=ok' "$AIRPLANES_978_RUNTIME_DIR/state"
}

@test "21: enabled + state-reader lib missing → reason stays ok (defensive)" {
    # If the state-reader.sh lib isn't installed, the wrapper falls back
    # to a stub that always returns rc=1. peer refinement degrades to a
    # no-op; we get the plain enabled-ok tile.
    write_peer_state disabled no_hardware
    STATE_READER_LIB="/nonexistent/state-reader.sh" run_wrapper "127.0.0.1:30978"
    [ "$status" -eq 0 ]
    grep -Fxq 'reason=ok' "$AIRPLANES_978_RUNTIME_DIR/state"
}

@test "22: disabled (UAT off) is never refined to peer_no_hardware" {
    # The peer might write no_hardware on a UAT-off boot too (depends on
    # systemd ordering); the consumer's reason must stay uat_disabled
    # when its OWN classification says disabled.
    write_peer_state disabled no_hardware
    run_wrapper ""
    [ "$status" -eq 0 ]
    grep -Fxq 'reason=uat_disabled' "$AIRPLANES_978_RUNTIME_DIR/state"
}
