#!/usr/bin/env bats

# Tests for airplanes-978.sh — the UAT relay wrapper. The wrapper reads
# UAT_INPUT from the EnvironmentFile-loaded env, classifies into
# enabled / disabled / misconfigured, writes /run/airplanes-978/state via
# state-writer.sh, and either execs the daemon or exits 64.
#
# Test hooks consumed:
#   AIRPLANES_978_RUNTIME_DIR — state file path + cleanup target
#   AIRPLANES_978_BIN          — binary stub (avoids real /usr/bin/airplanes-978)
#   STATE_WRITER_LIB           — points at the source-tree state-writer.sh

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/02-install-decoder/files/usr/local/share/airplanes/airplanes-978.sh"
    # state-writer.sh is shipped from the feed repo; the worktree is the
    # image repo, so point at the workspace-rooted feed path.
    STATE_WRITER_LIB="$BATS_TEST_DIRNAME/../../../../../../feed/scripts/lib/state-writer.sh"
    if [[ ! -r "$STATE_WRITER_LIB" ]]; then
        # Fallback: many CI envs unpack feed sibling-of-image. Try the standard
        # workspace layout above the .claude path traversal.
        STATE_WRITER_LIB="$BATS_TEST_DIRNAME/../../../../../feed/scripts/lib/state-writer.sh"
    fi
    [ -r "$STATE_WRITER_LIB" ]

    TMP="$(mktemp -d)"
    AIRPLANES_978_RUNTIME_DIR="$TMP/run-airplanes-978"
    mkdir -p "$AIRPLANES_978_RUNTIME_DIR"

    # Stub the binary: writes its argv to a marker file and exits 0.
    AIRPLANES_978_BIN="$TMP/airplanes-978-bin"
    cat > "$AIRPLANES_978_BIN" <<EOF
#!/bin/bash
echo "executed: \$*" > "$TMP/binary-invoked"
exit 0
EOF
    chmod +x "$AIRPLANES_978_BIN"

    export AIRPLANES_978_RUNTIME_DIR
    export AIRPLANES_978_BIN
    export STATE_WRITER_LIB
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

# ---- UAT_INPUT="" → state=disabled, exit 64 -------------------------------

@test "01: UAT_INPUT empty → state=disabled reason=uat_disabled, exit 64" {
    run_wrapper ""
    [ "$status" -eq 64 ]
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
    [ "$status" -eq 64 ]
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
    [ "$status" -eq 64 ]
    [ ! -e "$AIRPLANES_978_RUNTIME_DIR/aircraft.json" ]
    [ ! -e "$AIRPLANES_978_RUNTIME_DIR/receiver.json" ]
    [ ! -e "$AIRPLANES_978_RUNTIME_DIR/stats.json" ]
}

@test "12: state file survives the cleanup (state is not *.json)" {
    : > "$AIRPLANES_978_RUNTIME_DIR/aircraft.json"

    run_wrapper ""
    [ "$status" -eq 64 ]
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
    [ "$status" -eq 64 ]
    # State file is NOT written (no library to write it), but the daemon
    # correctly self-disables — degrades to systemd-only rendering, which
    # is the documented fallback.
    [ ! -e "$AIRPLANES_978_RUNTIME_DIR/state" ]
}
