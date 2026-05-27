#!/usr/bin/env bats

# Trampoline contract:
#   - When the runtime-shipped orchestrator binary is missing, the
#     trampoline exits 75 (EX_TEMPFAIL) so webconfig's capability gate
#     can translate it to HTTP 503.
#   - Same behaviour when the target is a directory rather than a regular
#     file.
#   - Same behaviour when the target is not executable.
#   - When the target is a regular executable file, the trampoline exec()s
#     it and forwards the exit code + argv.
#
# The trampoline pins an absolute path
# (/opt/airplanes-runtime/current/lib/airplanes-update-orchestrator), so
# the test must rewrite the file with the per-test temp path before
# running it. We do that via a tmp copy of the script that substitutes
# the target path with a tmpdir-relative one.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SRC_TRAMP="$REPO_ROOT/stage-airplanes/06d-cli-ergonomics/files/usr/local/lib/airplanes-webconfig/start-orchestrator.sh"
    [ -x "$SRC_TRAMP" ] || skip "trampoline missing or non-executable: $SRC_TRAMP"

    TMP="$BATS_TEST_TMPDIR"
    install -d -m 0755 "$TMP/lib"

    TARGET="$TMP/lib/airplanes-update-orchestrator"

    # Render a per-test copy of the trampoline that points at $TARGET
    # instead of /opt/airplanes-runtime/current/lib/...
    TRAMP="$TMP/start-orchestrator.sh"
    sed "s|/opt/airplanes-runtime/current/lib/airplanes-update-orchestrator|${TARGET}|" \
        "$SRC_TRAMP" > "$TRAMP"
    chmod 0755 "$TRAMP"
}

@test "exits 75 when target is missing" {
    [ ! -e "$TARGET" ]

    run bash "$TRAMP"
    [ "$status" -eq 75 ]
    [[ "$output" == *"target missing"* ]]
}

@test "exits 75 when target is a directory" {
    install -d -m 0755 "$TARGET"

    run bash "$TRAMP"
    [ "$status" -eq 75 ]
    [[ "$output" == *"target missing or not a regular file"* ]]
}

@test "exits 75 when target is not executable" {
    cat > "$TARGET" <<'EOF'
#!/usr/bin/env bash
echo "should not run"
exit 0
EOF
    chmod 0644 "$TARGET"

    run bash "$TRAMP"
    [ "$status" -eq 75 ]
    [[ "$output" == *"not executable"* ]]
}

@test "execs target when it is a regular executable file" {
    cat > "$TARGET" <<'EOF'
#!/usr/bin/env bash
echo "target executed"
echo "argv: $*"
exit 0
EOF
    chmod 0755 "$TARGET"

    run bash "$TRAMP" foo bar
    [ "$status" -eq 0 ]
    [[ "$output" == *"target executed"* ]]
    [[ "$output" == *"argv: foo bar"* ]]
}

@test "forwards non-zero exit code from target" {
    cat > "$TARGET" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
    chmod 0755 "$TARGET"

    run bash "$TRAMP"
    [ "$status" -eq 42 ]
}
