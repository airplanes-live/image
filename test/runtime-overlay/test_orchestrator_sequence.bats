#!/usr/bin/env bats

# Drives airplanes-update-orchestrator with every sub-helper stubbed out
# via PATH overrides and explicit AIRPLANES_ORCHESTRATOR_* env vars.
# Covers:
#   - all four steps run in declared order
#   - webconfig + runtime skip cleanly when the precheck reports no-op
#   - state file is valid JSON after every step
#   - HUP issued to webconfig after the feed step
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
        "$TMP/sub" \
        "$TMP/wcbin"

    STATE_FILE="$TMP/run/airplanes/orchestrator.state"
    CALL_LOG="$TMP/calls.log"
    : > "$CALL_LOG"

    # Sub-helper stubs — each records its invocation and exits 0 by
    # default. Tests override individual stubs to inject failures.
    cat > "$TMP/sub/feed-update.sh" <<EOF
#!/usr/bin/env bash
echo "feed \$*" >> "$CALL_LOG"
exit 0
EOF
    cat > "$TMP/sub/webconfig-update.sh" <<EOF
#!/usr/bin/env bash
echo "webconfig \$*" >> "$CALL_LOG"
exit 0
EOF
    cat > "$TMP/sub/runtime-update.sh" <<EOF
#!/usr/bin/env bash
echo "runtime \$*" >> "$CALL_LOG"
exit 0
EOF
    chmod 0755 \
        "$TMP/sub/feed-update.sh" \
        "$TMP/sub/webconfig-update.sh" \
        "$TMP/sub/runtime-update.sh"

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
    chmod 0755 "$TMP/bin/systemctl" "$TMP/bin/apt-get"

    # webconfig binary stub: by default present and reports newer (rc=0).
    # Tests can swap it to absent or rc!=0 to exercise the skip path.
    cat > "$TMP/wcbin/airplanes-webconfig" <<EOF
#!/usr/bin/env bash
echo "wcbin \$*" >> "$CALL_LOG"
exit 0
EOF
    chmod 0755 "$TMP/wcbin/airplanes-webconfig"
}

# Run the orchestrator with the stubbed environment. Args are passed
# through. Sets `status` and `output` per bats convention.
run_orchestrator() {
    run env -i \
        PATH="$TMP/bin:/usr/bin:/bin" \
        AIRPLANES_ORCHESTRATOR_STATE_FILE="$STATE_FILE" \
        AIRPLANES_ORCHESTRATOR_FEED_UPDATE="$TMP/sub/feed-update.sh" \
        AIRPLANES_ORCHESTRATOR_WEBCONFIG_UPDATE="$TMP/sub/webconfig-update.sh" \
        AIRPLANES_ORCHESTRATOR_RUNTIME_UPDATE="$TMP/sub/runtime-update.sh" \
        AIRPLANES_ORCHESTRATOR_WEBCONFIG_BINARY="$TMP/wcbin/airplanes-webconfig" \
        AIRPLANES_ORCHESTRATOR_WEBCONFIG_SERVICE="airplanes-webconfig.service" \
        AIRPLANES_ORCHESTRATOR_SYSTEMCTL="systemctl" \
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

@test "all four steps run in declared order; HUP after feed" {
    run_orchestrator
    [ "$status" -eq 0 ]
    assert_state_is_valid_json
    [ "$(state_step)" = "done" ]
    [ "$(state_status)" = "ok" ]

    # Sequence assertions: apt before feed before HUP before webconfig
    # before runtime. grep -n outputs line numbers in order.
    apt_line=$(grep -n '^apt-get update$' "$CALL_LOG" | head -1 | cut -d: -f1)
    feed_line=$(grep -n '^feed ' "$CALL_LOG" | head -1 | cut -d: -f1)
    hup_line=$(grep -n '^systemctl kill -s HUP airplanes-webconfig.service$' "$CALL_LOG" | head -1 | cut -d: -f1)
    wc_line=$(grep -n '^webconfig ' "$CALL_LOG" | head -1 | cut -d: -f1)
    rt_line=$(grep -n '^runtime ' "$CALL_LOG" | head -1 | cut -d: -f1)

    [ -n "$apt_line" ]
    [ -n "$feed_line" ]
    [ -n "$hup_line" ]
    [ -n "$wc_line" ]
    [ -n "$rt_line" ]
    [ "$apt_line" -lt "$feed_line" ]
    [ "$feed_line" -lt "$hup_line" ]
    [ "$hup_line" -lt "$wc_line" ]
    [ "$wc_line" -lt "$rt_line" ]
}

@test "apt step records apt_irreversible=true even after success" {
    run_orchestrator
    [ "$status" -eq 0 ]
    irreversible=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['apt_irreversible'])" "$STATE_FILE")
    [ "$irreversible" = "True" ]
}

@test "webconfig step fails when helper is missing" {
    # The webconfig precheck treats a missing binary as "no opinion, run
    # the helper" — the helper is authoritative. So if the helper itself
    # is missing, the step fails (rather than silently skipping).
    rm -f "$TMP/sub/webconfig-update.sh"

    run_orchestrator
    [ "$status" -ne 0 ]
    [ "$(state_step)" = "webconfig" ]
    [ "$(state_status)" = "failed" ]
}

@test "runtime step skips cleanly when runtime updater is absent" {
    # The runtime precheck only runs the helper if it is executable. A
    # missing helper means skip rather than fail — that is by design,
    # because a feeder without a runtime overlay yet (build-time race)
    # should not block the rest of the orchestrator.
    rm -f "$TMP/sub/runtime-update.sh"

    run_orchestrator
    [ "$status" -eq 0 ]
    assert_state_is_valid_json
    [ "$(state_step)" = "done" ]

    # No runtime invocation should appear in the call log.
    run grep '^runtime ' "$CALL_LOG"
    [ "$status" -ne 0 ]
}

@test "state file is valid JSON after every intermediate write" {
    # Run the orchestrator wrapping every state write with a side-channel
    # snapshot of the file. We approximate this by intercepting via a
    # 'cat' shim on each step that copies the state file aside.
    cat > "$TMP/sub/feed-update.sh" <<EOF
#!/usr/bin/env bash
cp -a "$STATE_FILE" "$TMP/state/snap-feed.json"
echo "feed \$*" >> "$CALL_LOG"
exit 0
EOF
    cat > "$TMP/sub/webconfig-update.sh" <<EOF
#!/usr/bin/env bash
cp -a "$STATE_FILE" "$TMP/state/snap-webconfig.json"
echo "webconfig \$*" >> "$CALL_LOG"
exit 0
EOF
    cat > "$TMP/sub/runtime-update.sh" <<EOF
#!/usr/bin/env bash
cp -a "$STATE_FILE" "$TMP/state/snap-runtime.json"
echo "runtime \$*" >> "$CALL_LOG"
exit 0
EOF
    chmod 0755 "$TMP/sub/feed-update.sh" "$TMP/sub/webconfig-update.sh" "$TMP/sub/runtime-update.sh"

    run_orchestrator
    [ "$status" -eq 0 ]

    for snap in "$TMP/state/snap-feed.json" "$TMP/state/snap-webconfig.json" "$TMP/state/snap-runtime.json"; do
        [ -f "$snap" ]
        python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$snap"
    done
}

@test "feed step failure writes status: failed and stops subsequent steps" {
    cat > "$TMP/sub/feed-update.sh" <<EOF
#!/usr/bin/env bash
echo "feed FAILED" >&2
exit 7
EOF
    chmod 0755 "$TMP/sub/feed-update.sh"

    run_orchestrator
    [ "$status" -ne 0 ]
    assert_state_is_valid_json
    [ "$(state_step)" = "feed" ]
    [ "$(state_status)" = "failed" ]

    # No HUP, no webconfig, no runtime calls after feed failure.
    run grep -E '^(systemctl kill -s HUP|webconfig|runtime) ' "$CALL_LOG"
    [ "$status" -ne 0 ]
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

    # apt_irreversible records that an apt run was attempted.
    irreversible=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['apt_irreversible'])" "$STATE_FILE")
    [ "$irreversible" = "True" ]

    # No feed / webconfig / runtime calls after apt failure.
    run grep -E '^(feed|webconfig|runtime) ' "$CALL_LOG"
    [ "$status" -ne 0 ]
}

@test "webconfig step failure stops the runtime step" {
    cat > "$TMP/sub/webconfig-update.sh" <<EOF
#!/usr/bin/env bash
echo "webconfig FAILED" >&2
exit 5
EOF
    chmod 0755 "$TMP/sub/webconfig-update.sh"

    run_orchestrator
    [ "$status" -ne 0 ]
    assert_state_is_valid_json
    [ "$(state_step)" = "webconfig" ]
    [ "$(state_status)" = "failed" ]

    run grep '^runtime ' "$CALL_LOG"
    [ "$status" -ne 0 ]
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

@test "state file is created atomically (no half-written reads)" {
    # The atomic-write pattern (tmp + mv -f) guarantees a reader always
    # sees a complete JSON object. We assert the property indirectly by
    # confirming no .tmp leftover file remains after a clean run.
    run_orchestrator
    [ "$status" -eq 0 ]

    run find "$TMP/run/airplanes" -name 'orchestrator.state.*' -type f
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
