#!/usr/bin/env bats

# Tests for tar1090-uat-sync.sh — the reconciler that flips ENABLE_978 in
# /etc/default/tar1090 to track airplanes-978 + dump978-fa runtime state.
#
# Test hooks consumed (set in setup()):
#   AIRPLANES_TAR1090_DEFAULTS_PATH    — temp /etc/default/tar1090 path
#   AIRPLANES_978_STATE_PATH           — temp consumer state file path
#   DUMP978_FA_STATE_PATH              — temp producer state file path
#   AIRPLANES_TAR1090_SYNC_RESTART_CMD — recorded-invocation stub
#   STATE_READER_LIB                   — points at an inline minimal reader

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/03-install-tar1090/files/usr/local/share/airplanes/tar1090-uat-sync.sh"
    TMP="$(mktemp -d)"

    # Minimal airplanes_read_state mirroring the contract from
    # feed/scripts/lib/state-reader.sh (schema_version=1 first line,
    # KEY=VALUE in caller order, returns value on stdout for the key
    # requested, rc 0 on hit / rc 1 on miss).
    STATE_READER_LIB="$TMP/state-reader.sh"
    cat > "$STATE_READER_LIB" <<'READER'
airplanes_read_state() {
    local file="$1" key="$2"
    [[ -f "$file" && -r "$file" ]] || return 1
    local first=1 line
    while IFS= read -r line; do
        if (( first )); then
            first=0
            [[ "$line" == 'schema_version=1' ]] || return 1
            continue
        fi
        case "$line" in
            "${key}="*)
                printf '%s' "${line#"${key}="}"
                return 0
                ;;
        esac
    done < "$file"
    return 1
}
READER

    AIRPLANES_TAR1090_DEFAULTS_PATH="$TMP/tar1090.defaults"
    AIRPLANES_978_STATE_PATH="$TMP/airplanes-978-state"
    DUMP978_FA_STATE_PATH="$TMP/dump978-fa-state"

    # Restart stub: append its invocation arguments to a marker file so tests
    # can count and inspect calls. Acts as the AIRPLANES_TAR1090_SYNC_RESTART_CMD
    # — the reconciler invokes it unquoted via word-splitting, so the stub
    # is a real binary on PATH.
    RESTART_LOG="$TMP/restart.log"
    RESTART_BIN="$TMP/restart-stub"
    cat > "$RESTART_BIN" <<EOF
#!/bin/bash
printf 'invocation: %s\n' "\$*" >> "$RESTART_LOG"
exit 0
EOF
    chmod +x "$RESTART_BIN"
    AIRPLANES_TAR1090_SYNC_RESTART_CMD="$RESTART_BIN"

    export STATE_READER_LIB
    export AIRPLANES_TAR1090_DEFAULTS_PATH
    export AIRPLANES_978_STATE_PATH
    export DUMP978_FA_STATE_PATH
    export AIRPLANES_TAR1090_SYNC_RESTART_CMD
}

teardown() { rm -rf "$TMP"; }

# Helper: write a state file with the given key/value pairs in schema-v1
# format. Caller passes "state=enabled" "reason=ok" ... .
write_state() {
    local target="$1"; shift
    mkdir -p "$(dirname "$target")"
    {
        printf 'schema_version=1\n'
        for kv in "$@"; do
            printf '%s\n' "$kv"
        done
    } > "$target"
}

# Helper: prime /etc/default/tar1090 with the given ENABLE_978 value (or
# omit to leave the key absent).
write_defaults() {
    local value="${1-}"
    {
        printf '# /etc/default/tar1090 — test fixture\n'
        printf 'INTERVAL=1\n'
        if [[ -n "$value" ]]; then
            printf 'ENABLE_978=%s\n' "$value"
        fi
        printf 'PTRACKS=8\n'
    } > "$AIRPLANES_TAR1090_DEFAULTS_PATH"
}

# Helper: read current ENABLE_978 value from the test fixture (empty if absent).
current_value() {
    awk -F= '/^ENABLE_978=/ { print $2; exit }' "$AIRPLANES_TAR1090_DEFAULTS_PATH"
}

# Helper: count restart-stub invocations.
restart_count() {
    [[ -f "$RESTART_LOG" ]] || { echo 0; return; }
    wc -l < "$RESTART_LOG" | tr -d ' '
}

run_sync() {
    run bash "$SCRIPT"
}

# ---- desired=no paths (missing/disabled state) ---------------------------

@test "01: both state files missing → desired=no" {
    write_defaults "yes"
    run_sync
    [ "$status" -eq 0 ]
    [ "$(current_value)" = "no" ]
    [ "$(restart_count)" -eq 1 ]
}

@test "02: consumer state file missing → desired=no" {
    write_defaults "yes"
    write_state "$DUMP978_FA_STATE_PATH" "service=dump978-fa" "state=enabled" "reason=ok"
    run_sync
    [ "$status" -eq 0 ]
    [ "$(current_value)" = "no" ]
}

@test "03: producer state file missing → desired=no" {
    write_defaults "yes"
    write_state "$AIRPLANES_978_STATE_PATH" "service=airplanes-978" "state=enabled" "reason=ok"
    run_sync
    [ "$status" -eq 0 ]
    [ "$(current_value)" = "no" ]
}

@test "04: consumer disabled (UAT_INPUT empty) → desired=no" {
    write_defaults "yes"
    write_state "$AIRPLANES_978_STATE_PATH" "service=airplanes-978" "state=disabled" "reason=uat_disabled"
    write_state "$DUMP978_FA_STATE_PATH" "service=dump978-fa" "state=disabled" "reason=uat_disabled"
    run_sync
    [ "$status" -eq 0 ]
    [ "$(current_value)" = "no" ]
}

@test "05: producer disabled/no_hardware (consumer stale enabled/ok) → desired=no" {
    # Hot-unplug case: consumer state was sampled when SDR was present, but
    # the SDR has since been removed and dump978-fa noticed. Trust the
    # live producer state.
    write_defaults "yes"
    write_state "$AIRPLANES_978_STATE_PATH" "service=airplanes-978" "state=enabled" "reason=ok"
    write_state "$DUMP978_FA_STATE_PATH" "service=dump978-fa" "state=disabled" "reason=no_hardware"
    run_sync
    [ "$status" -eq 0 ]
    [ "$(current_value)" = "no" ]
}

@test "06: consumer enabled+peer_no_hardware + producer ok → desired=yes" {
    # Hot-plug case: consumer state captured peer_no_hardware at activation,
    # but dump978-fa subsequently found the SDR. We ignore consumer.reason
    # and look at producer.state directly.
    write_defaults "no"
    write_state "$AIRPLANES_978_STATE_PATH" "service=airplanes-978" "state=enabled" "reason=peer_no_hardware"
    write_state "$DUMP978_FA_STATE_PATH" "service=dump978-fa" "state=enabled" "reason=ok"
    run_sync
    [ "$status" -eq 0 ]
    [ "$(current_value)" = "yes" ]
}

@test "07: both enabled/ok → desired=yes" {
    write_defaults "no"
    write_state "$AIRPLANES_978_STATE_PATH" "service=airplanes-978" "state=enabled" "reason=ok"
    write_state "$DUMP978_FA_STATE_PATH" "service=dump978-fa" "state=enabled" "reason=ok"
    run_sync
    [ "$status" -eq 0 ]
    [ "$(current_value)" = "yes" ]
}

# ---- idempotency / restart accounting ------------------------------------

@test "08: current=no + desired=no → no restart, no rewrite" {
    write_defaults "no"
    local before
    before="$(stat -c %Y "$AIRPLANES_TAR1090_DEFAULTS_PATH")"
    sleep 1  # ensure any rewrite would change mtime visibly
    run_sync
    [ "$status" -eq 0 ]
    [ "$(restart_count)" -eq 0 ]
    [ "$(stat -c %Y "$AIRPLANES_TAR1090_DEFAULTS_PATH")" -eq "$before" ]
}

@test "09: current=yes + desired=yes → no restart" {
    write_defaults "yes"
    write_state "$AIRPLANES_978_STATE_PATH" "service=airplanes-978" "state=enabled" "reason=ok"
    write_state "$DUMP978_FA_STATE_PATH" "service=dump978-fa" "state=enabled" "reason=ok"
    run_sync
    [ "$status" -eq 0 ]
    [ "$(restart_count)" -eq 0 ]
}

@test "10: transition no→yes invokes restart exactly once" {
    write_defaults "no"
    write_state "$AIRPLANES_978_STATE_PATH" "service=airplanes-978" "state=enabled" "reason=ok"
    write_state "$DUMP978_FA_STATE_PATH" "service=dump978-fa" "state=enabled" "reason=ok"
    run_sync
    [ "$status" -eq 0 ]
    [ "$(restart_count)" -eq 1 ]
}

@test "11: transition yes→no invokes restart exactly once" {
    write_defaults "yes"
    write_state "$AIRPLANES_978_STATE_PATH" "service=airplanes-978" "state=disabled" "reason=uat_disabled"
    write_state "$DUMP978_FA_STATE_PATH" "service=dump978-fa" "state=disabled" "reason=uat_disabled"
    run_sync
    [ "$status" -eq 0 ]
    [ "$(current_value)" = "no" ]
    [ "$(restart_count)" -eq 1 ]
}

# ---- defaults file shapes ------------------------------------------------

@test "12: ENABLE_978= absent → script appends it" {
    write_defaults ""  # no ENABLE_978 line at all
    run_sync
    [ "$status" -eq 0 ]
    [ "$(current_value)" = "no" ]
    # Other lines preserved.
    grep -Fxq 'INTERVAL=1' "$AIRPLANES_TAR1090_DEFAULTS_PATH"
    grep -Fxq 'PTRACKS=8' "$AIRPLANES_TAR1090_DEFAULTS_PATH"
    [ "$(restart_count)" -eq 1 ]
}

@test "13: commented #ENABLE_978=yes ignored, real line appended" {
    {
        printf 'INTERVAL=1\n'
        printf '#ENABLE_978=yes\n'
        printf 'PTRACKS=8\n'
    } > "$AIRPLANES_TAR1090_DEFAULTS_PATH"
    run_sync
    [ "$status" -eq 0 ]
    # The commented line is untouched, and a real assignment lands.
    grep -Fxq '#ENABLE_978=yes' "$AIRPLANES_TAR1090_DEFAULTS_PATH"
    grep -Fxq 'ENABLE_978=no' "$AIRPLANES_TAR1090_DEFAULTS_PATH"
}

@test "14: mode is preserved across rewrite" {
    write_defaults "yes"
    chmod 0640 "$AIRPLANES_TAR1090_DEFAULTS_PATH"
    run_sync
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$AIRPLANES_TAR1090_DEFAULTS_PATH")" = "640" ]
}

# ---- defensive: missing state-reader lib ---------------------------------

@test "15: missing state-reader lib → reconcile still settles to no" {
    write_defaults "yes"
    write_state "$AIRPLANES_978_STATE_PATH" "service=airplanes-978" "state=enabled" "reason=ok"
    write_state "$DUMP978_FA_STATE_PATH" "service=dump978-fa" "state=enabled" "reason=ok"
    STATE_READER_LIB="/nonexistent/state-reader.sh" run_sync
    [ "$status" -eq 0 ]
    # Without the reader, every read returns rc 1 → desired=no.
    [ "$(current_value)" = "no" ]
}
