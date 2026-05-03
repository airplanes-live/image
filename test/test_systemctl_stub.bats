#!/usr/bin/env bats

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    STUB="$REPO_ROOT/scripts/systemctl-stub"
    TMP="$(mktemp -d)"
    LOG="$TMP/stub.log"
    REAL_LOG="$TMP/real.log"
    REAL="$TMP/real-systemctl"
    SYSTEMCTL_LINK="$TMP/systemctl"
    ln -sf "$STUB" "$SYSTEMCTL_LINK"
    cat > "$REAL" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$@" >> "$REAL_LOG"
exit 0
SH
    chmod +x "$REAL"
}

teardown() {
    rm -rf "$TMP"
}

invoke() {
    AIRPLANES_STUB_LOG="$LOG" \
    AIRPLANES_REAL_SYSTEMCTL="$REAL" \
        "$SYSTEMCTL_LINK" "$@"
}

invoke_as() {
    local alias_name="$1"; shift
    local alias_path="$TMP/$alias_name"
    ln -sf "$STUB" "$alias_path"
    AIRPLANES_STUB_LOG="$LOG" \
    AIRPLANES_REAL_SYSTEMCTL="$REAL" \
        "$alias_path" "$@"
}

assert_no_passthrough() {
    [ ! -s "$REAL_LOG" ]
}

assert_passthrough_received() {
    [ -s "$REAL_LOG" ]
    grep -q -- "$1" "$REAL_LOG"
}

@test "start logs invocation, exits 0, does not pass through" {
    run invoke start airplanes-feed
    [ "$status" -eq 0 ]
    assert_no_passthrough
    grep -q 'systemctl start airplanes-feed' "$LOG"
}

@test "restart exits 0 without pass-through" {
    run invoke restart airplanes-feed
    [ "$status" -eq 0 ]
    assert_no_passthrough
}

@test "stop exits 0 without pass-through" {
    run invoke stop airplanes-feed
    [ "$status" -eq 0 ]
    assert_no_passthrough
}

@test "reload, try-restart, reload-or-restart, kill all exit 0 without pass-through" {
    for verb in reload try-restart reload-or-restart kill; do
        rm -f "$REAL_LOG"
        run invoke "$verb" airplanes-feed
        [ "$status" -eq 0 ]
        assert_no_passthrough
    done
}

@test "daemon-reload exits 0 without pass-through" {
    run invoke daemon-reload
    [ "$status" -eq 0 ]
    assert_no_passthrough
}

@test "daemon-reexec exits 0 without pass-through" {
    run invoke daemon-reexec
    [ "$status" -eq 0 ]
    assert_no_passthrough
}

@test "is-active exits 1 without pass-through (signals not running)" {
    run invoke is-active airplanes-feed
    [ "$status" -eq 1 ]
    assert_no_passthrough
}

@test "is-failed exits 1 without pass-through" {
    run invoke is-failed airplanes-feed
    [ "$status" -eq 1 ]
    assert_no_passthrough
}

@test "enable passes through to real systemctl with full argv" {
    run invoke enable airplanes-feed
    [ "$status" -eq 0 ]
    assert_passthrough_received "enable"
    assert_passthrough_received "airplanes-feed"
}

@test "disable, mask, unmask, is-enabled, preset, preset-all, reenable, link pass through" {
    for verb in disable mask unmask is-enabled preset preset-all reenable link; do
        rm -f "$REAL_LOG"
        run invoke "$verb" some-unit
        [ "$status" -eq 0 ]
        assert_passthrough_received "$verb"
    done
}

@test "read-only verbs (cat, show, status, list-units) pass through" {
    for verb in cat show status list-units; do
        rm -f "$REAL_LOG"
        run invoke "$verb" airplanes-feed
        [ "$status" -eq 0 ]
        assert_passthrough_received "$verb"
    done
}

@test "invoked as service: exits 0 unconditionally without pass-through" {
    run invoke_as service start airplanes-feed
    [ "$status" -eq 0 ]
    assert_no_passthrough
    grep -q 'service start airplanes-feed' "$LOG"
}

@test "invoked as deb-systemd-invoke: exits 0 unconditionally without pass-through" {
    run invoke_as deb-systemd-invoke restart some-unit
    [ "$status" -eq 0 ]
    assert_no_passthrough
    grep -q 'deb-systemd-invoke restart some-unit' "$LOG"
}

@test "log entry contains ISO8601 timestamp and basename" {
    run invoke enable airplanes-feed
    [ "$status" -eq 0 ]
    grep -E -q '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] systemctl enable airplanes-feed$' "$LOG"
}

@test "stub does not abort when LOG path is unwritable" {
    run env AIRPLANES_STUB_LOG=/proc/1/cannot-write \
        AIRPLANES_REAL_SYSTEMCTL="$REAL" \
        bash "$STUB" enable some-unit
    [ "$status" -eq 0 ]
}
