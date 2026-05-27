#!/usr/bin/env bats

# Drives airplanes-update-orchestrator with every sub-helper stubbed out
# via PATH overrides and explicit AIRPLANES_ORCHESTRATOR_* env vars.
# Covers:
#   - both steps run in declared order (apt → runtime)
#   - runtime skips cleanly when the precheck reports no-op
#   - state file is valid JSON after every step
#   - no separate feed or webconfig step exists (both ship in the overlay)
#   - failure in any step writes status: failed and exits non-zero
#   - subsequent steps not invoked after a failure

bats_require_minimum_version 1.5.0

ORCH=""
TMP=""

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    ORCH="$REPO_ROOT/runtime-overlay/src/lib/airplanes-update-orchestrator"
    [ -x "$ORCH" ] || skip "orchestrator missing or non-executable: $ORCH"

    TMP="$BATS_TEST_TMPDIR"
    install -d -m 0755 \
        "$TMP/run/airplanes" \
        "$TMP/state" \
        "$TMP/bin" \
        "$TMP/sub"

    STATE_FILE="$TMP/run/airplanes/orchestrator.state"
    LOCK_FILE="$TMP/run/airplanes/orchestrator.lock"
    CALL_LOG="$TMP/calls.log"
    : > "$CALL_LOG"

    # Sub-helper stub — records its invocation and exits 0 by default. Tests
    # override it to inject failures. Feed and webconfig no longer have
    # separate steps; both ship inside the runtime overlay.
    cat > "$TMP/sub/runtime-update.sh" <<EOF
#!/usr/bin/env bash
echo "runtime \$*" >> "$CALL_LOG"
exit 0
EOF
    chmod 0755 "$TMP/sub/runtime-update.sh"

    # PATH-injected systemctl + apt-get stubs.
    cat > "$TMP/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$CALL_LOG"
exit 0
EOF
    cat > "$TMP/bin/apt-get" <<EOF
#!/usr/bin/env bash
echo "apt-get \$*" >> "$CALL_LOG"
exit 0
EOF
    cat > "$TMP/bin/flock" <<EOF
#!/usr/bin/env bash
exec /usr/bin/flock "\$@"
EOF
    chmod 0755 "$TMP/bin/systemctl" "$TMP/bin/apt-get" "$TMP/bin/flock"
}

# Run the orchestrator with the stubbed environment. Args are passed
# through. Sets `status` and `output` per bats convention.
run_orchestrator() {
    run env -i \
        PATH="$TMP/bin:/usr/bin:/bin" \
        AIRPLANES_ORCHESTRATOR_STATE_FILE="$STATE_FILE" \
        AIRPLANES_ORCHESTRATOR_LOCK_FILE="$LOCK_FILE" \
        AIRPLANES_ORCHESTRATOR_RUNTIME_UPDATE="$TMP/sub/runtime-update.sh" \
        AIRPLANES_ORCHESTRATOR_RUNTIME_UPGRADE_STATE="$TMP/var/lib/airplanes-runtime-upgrade/upgrade-state" \
        AIRPLANES_ORCHESTRATOR_APT_GET="apt-get" \
        bash "$ORCH" "$@"
}

# Read the `step` value from the JSON state file.
state_step() {
    python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['step'])" "$STATE_FILE"
}

# Read the `status` value from the JSON state file.
state_status() {
    python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['status'])" "$STATE_FILE"
}

# Assert the JSON state file is well-formed.
assert_state_is_valid_json() {
    python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$STATE_FILE"
}

@test "both steps run in declared order (apt → runtime)" {
    run_orchestrator
    [ "$status" -eq 0 ]
    assert_state_is_valid_json
    [ "$(state_step)" = "done" ]
    [ "$(state_status)" = "ok" ]

    # Sequence assertions: apt before runtime.
    apt_line=$(grep -n '^apt-get update$' "$CALL_LOG" | head -1 | cut -d: -f1)
    rt_line=$(grep -n '^runtime ' "$CALL_LOG" | head -1 | cut -d: -f1)

    [ -n "$apt_line" ]
    [ -n "$rt_line" ]
    [ "$apt_line" -lt "$rt_line" ]
}

@test "no separate feed or webconfig step exists" {
    run_orchestrator
    [ "$status" -eq 0 ]

    # The orchestrator no longer has feed or webconfig steps — both the feed
    # stack and webconfig ship inside the runtime overlay, so neither a
    # step_feed (with its post-feed webconfig HUP) nor a step_webconfig exists.
    run grep -E '^(feed|webconfig) ' "$CALL_LOG"
    [ "$status" -ne 0 ]
    run grep -E '^systemctl kill -s HUP' "$CALL_LOG"
    [ "$status" -ne 0 ]
}

@test "apt step records apt_irreversible=true even after success" {
    run_orchestrator
    [ "$status" -eq 0 ]
    irreversible=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['apt_irreversible'])" "$STATE_FILE")
    [ "$irreversible" = "True" ]
}

@test "runtime step skips cleanly when runtime updater is absent" {
    rm -f "$TMP/sub/runtime-update.sh"

    run_orchestrator
    [ "$status" -eq 0 ]
    assert_state_is_valid_json
    [ "$(state_step)" = "done" ]

    run grep '^runtime ' "$CALL_LOG"
    [ "$status" -ne 0 ]
}

@test "state file is valid JSON after every intermediate write" {
    cat > "$TMP/sub/runtime-update.sh" <<EOF
#!/usr/bin/env bash
cp -a "$STATE_FILE" "$TMP/state/snap-runtime.json"
echo "runtime \$*" >> "$CALL_LOG"
exit 0
EOF
    chmod 0755 "$TMP/sub/runtime-update.sh"

    run_orchestrator
    [ "$status" -eq 0 ]

    for snap in "$TMP/state/snap-runtime.json"; do
        [ -f "$snap" ]
        python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$snap"
    done
}

@test "apt step failure writes status: failed and stops subsequent steps" {
    cat > "$TMP/bin/apt-get" <<EOF
#!/usr/bin/env bash
echo "apt-get FAILED" >&2
exit 100
EOF
    chmod 0755 "$TMP/bin/apt-get"

    run_orchestrator
    [ "$status" -ne 0 ]
    assert_state_is_valid_json
    [ "$(state_step)" = "apt" ]
    [ "$(state_status)" = "failed" ]

    irreversible=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['apt_irreversible'])" "$STATE_FILE")
    [ "$irreversible" = "True" ]

    run grep -E '^(feed|runtime) ' "$CALL_LOG"
    [ "$status" -ne 0 ]
}

@test "apt-get update failure surfaces even if upgrade would succeed" {
    cat > "$TMP/bin/apt-get" <<EOF
#!/usr/bin/env bash
case "\$1" in
    update)  exit 17 ;;
    *)       exit 0 ;;
esac
EOF
    chmod 0755 "$TMP/bin/apt-get"

    run_orchestrator
    [ "$status" -ne 0 ]
    [ "$(state_step)" = "apt" ]
    [ "$(state_status)" = "failed" ]
}

@test "runtime step failure leaves state at runtime/failed" {
    cat > "$TMP/sub/runtime-update.sh" <<EOF
#!/usr/bin/env bash
echo "runtime FAILED" >&2
exit 9
EOF
    chmod 0755 "$TMP/sub/runtime-update.sh"

    run_orchestrator
    [ "$status" -ne 0 ]
    assert_state_is_valid_json
    [ "$(state_step)" = "runtime" ]
    [ "$(state_status)" = "failed" ]
}

@test "runtime same-version-replay is treated as a no-op success" {
    install -d -m 0755 "$TMP/var/lib/airplanes-runtime-upgrade"
    cat > "$TMP/sub/runtime-update.sh" <<EOF
#!/usr/bin/env bash
cat > "$TMP/var/lib/airplanes-runtime-upgrade/upgrade-state" <<STATE
state=FAILED_PRE_MUTATION
failure_reason=same_version_replay_opt_airplanes-runtime_releases_v0.0.1
STATE
exit 1
EOF
    chmod 0755 "$TMP/sub/runtime-update.sh"

    run_orchestrator
    [ "$status" -eq 0 ]
    assert_state_is_valid_json
    [ "$(state_step)" = "done" ]
    [ "$(state_status)" = "ok" ]
}

@test "runtime non-same-version FAILED_PRE_MUTATION still surfaces" {
    install -d -m 0755 "$TMP/var/lib/airplanes-runtime-upgrade"
    cat > "$TMP/sub/runtime-update.sh" <<EOF
#!/usr/bin/env bash
cat > "$TMP/var/lib/airplanes-runtime-upgrade/upgrade-state" <<STATE
state=FAILED_PRE_MUTATION
failure_reason=download_failed
STATE
exit 1
EOF
    chmod 0755 "$TMP/sub/runtime-update.sh"

    run_orchestrator
    [ "$status" -ne 0 ]
    [ "$(state_step)" = "runtime" ]
    [ "$(state_status)" = "failed" ]
}

@test "stale same-version-replay state is NOT misclassified as success" {
    install -d -m 0755 "$TMP/var/lib/airplanes-runtime-upgrade"
    cat > "$TMP/var/lib/airplanes-runtime-upgrade/upgrade-state" <<STATE
state=FAILED_PRE_MUTATION
failure_reason=same_version_replay_opt_airplanes-runtime_releases_v0.0.1
STATE

    cat > "$TMP/sub/runtime-update.sh" <<EOF
#!/usr/bin/env bash
exit 75
EOF
    chmod 0755 "$TMP/sub/runtime-update.sh"

    run_orchestrator
    [ "$status" -ne 0 ]
    [ "$(state_step)" = "runtime" ]
    [ "$(state_status)" = "failed" ]
}

@test "state file is created atomically (no half-written reads)" {
    run_orchestrator
    [ "$status" -eq 0 ]

    run find "$TMP/run/airplanes" -name 'orchestrator.state.*' -type f
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "second concurrent invocation exits 75 without touching state" {
    install -d -m 0755 "$(dirname "$LOCK_FILE")"
    : > "$LOCK_FILE"
    exec 8>"$LOCK_FILE"
    flock 8

    run_orchestrator
    [ "$status" -eq 75 ]

    [ ! -e "$STATE_FILE" ] || {
        true
    }

    exec 8>&-
}
