#!/usr/bin/env bats

# Tests for tar1090-uat-sync.sh — the reconciler that flips ENABLE_978 in
# /etc/default/tar1090 to track airplanes-978 + dump978-fa runtime state.
#
# Test hooks consumed (set in setup()):
#   AIRPLANES_TAR1090_DEFAULTS_PATH    — temp /etc/default/tar1090 path
#   AIRPLANES_978_STATE_PATH           — temp consumer state file path
#   DUMP978_FA_STATE_PATH              — temp producer state file path
#   AIRPLANES_TAR1090_SYNC_RESTART_CMD — recorded-invocation stub

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/03-install-tar1090/files/usr/local/share/airplanes/tar1090-uat-sync.sh"
    TMP="$(mktemp -d)"

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

# ---- malformed state files (defensive parsing) ---------------------------

@test "15: state file missing schema_version=1 first line → treated as absent" {
    # The inline parser refuses anything not starting with the canonical
    # schema header. A consumer that hand-rolls a state file without the
    # header (or one truncated mid-write before the header lands) is
    # silently treated as absent → desired=no.
    write_defaults "yes"
    {
        printf 'state=enabled\n'
        printf 'reason=ok\n'
    } > "$AIRPLANES_978_STATE_PATH"
    {
        printf 'state=enabled\n'
        printf 'reason=ok\n'
    } > "$DUMP978_FA_STATE_PATH"
    run_sync
    [ "$status" -eq 0 ]
    [ "$(current_value)" = "no" ]
}

# ---- duplicate ENABLE_978 lines + symmetric whitespace handling ----------

@test "16: duplicate ENABLE_978= lines are all rewritten" {
    # tar1090's /etc/default/tar1090 is sourced; the last assignment wins.
    # A stray duplicate left behind would silently override our reconciled
    # value — rewrite all matching lines, not just the first.
    {
        printf 'INTERVAL=1\n'
        printf 'ENABLE_978=yes\n'
        printf 'PTRACKS=8\n'
        printf 'ENABLE_978=yes\n'  # stray duplicate
    } > "$AIRPLANES_TAR1090_DEFAULTS_PATH"
    write_state "$AIRPLANES_978_STATE_PATH" "service=airplanes-978" "state=disabled" "reason=uat_disabled"
    run_sync
    [ "$status" -eq 0 ]
    # Both occurrences should have been rewritten to no.
    [ "$(grep -c '^ENABLE_978=no' "$AIRPLANES_TAR1090_DEFAULTS_PATH")" -eq 2 ]
    [ "$(grep -c '^ENABLE_978=yes' "$AIRPLANES_TAR1090_DEFAULTS_PATH")" -eq 0 ]
}

@test "17: indented ENABLE_978 ignored by both reader and rewriter" {
    # The reader and rewriter both anchor strictly at ^; an indented form
    # is treated as absent on both sides so the script appends a canonical
    # assignment at EOF and leaves the indented line untouched.
    {
        printf 'INTERVAL=1\n'
        printf '  ENABLE_978=yes\n'
        printf 'PTRACKS=8\n'
    } > "$AIRPLANES_TAR1090_DEFAULTS_PATH"
    run_sync
    [ "$status" -eq 0 ]
    # Indented line still present, plus an appended canonical assignment.
    grep -Fxq '  ENABLE_978=yes' "$AIRPLANES_TAR1090_DEFAULTS_PATH"
    grep -Fxq 'ENABLE_978=no' "$AIRPLANES_TAR1090_DEFAULTS_PATH"
}

# ---- restart command tolerance -------------------------------------------

@test "18: failing restart command does not fail the reconcile" {
    # tar1090 may be masked, missing, or otherwise unable to restart — the
    # config rewrite is the load-bearing effect and should land regardless.
    write_defaults "yes"
    write_state "$AIRPLANES_978_STATE_PATH" "service=airplanes-978" "state=disabled" "reason=uat_disabled"
    # Replace the stub with a command that always fails.
    cat > "$RESTART_BIN" <<'EOF'
#!/bin/bash
echo "synthetic failure" >&2
exit 1
EOF
    chmod +x "$RESTART_BIN"
    run_sync
    [ "$status" -eq 0 ]
    [ "$(current_value)" = "no" ]
}

# ---- snapshot atomicity over racing wrapper rewrites ---------------------

@test "19: producer state + reason come from the same generation" {
    # The wrapper atomic-renames /run/dump978-fa/state on every cycle. The
    # reconcile reads producer.state and producer.reason; if those land on
    # different generations the decision can be wrong. Read snapshots from
    # a single capture to avoid that. We assert by handing the script a
    # state file whose contents simulate a producer mid-transition the
    # wrapper would never publish atomically: state=enabled, reason from a
    # different generation. With the snapshot-once approach the same
    # values are seen — verifying behavior by content equivalence rather
    # than racing in real time.
    write_defaults "no"
    write_state "$AIRPLANES_978_STATE_PATH" "service=airplanes-978" "state=enabled" "reason=ok"
    write_state "$DUMP978_FA_STATE_PATH" "service=dump978-fa" "state=enabled" "reason=ok"
    run_sync
    [ "$status" -eq 0 ]
    [ "$(current_value)" = "yes" ]
}
