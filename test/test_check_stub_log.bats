#!/usr/bin/env bats

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO_ROOT/scripts/check-stub-log.sh"
    TMP="$(mktemp -d)"
    ROOT="$TMP/r"
    LOG="$ROOT/var/log/airplanes-systemctl-stub.log"
    FINGERPRINT="$ROOT/etc/airplanes/.build-stub-fingerprint"
    mkdir -p "$(dirname "$LOG")"
}

teardown() {
    rm -rf "$TMP"
}

write_log() {
    : > "$LOG"
    for line in "$@"; do
        printf '%s\n' "$line" >> "$LOG"
    done
}

@test "empty log fails with missing-or-empty error" {
    : > "$LOG"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "missing or empty" ]] || [[ "$stderr" =~ "missing or empty" ]] || true
    [ ! -e "$FINGERPRINT" ]
}

@test "log with start verb fails with forbidden-lifecycle-verbs error" {
    write_log \
        "[2026-05-03T12:00:00Z] systemctl enable airplanes-feed" \
        "[2026-05-03T12:00:01Z] systemctl start airplanes-feed"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -ne 0 ]
    [ ! -e "$FINGERPRINT" ]
}

@test "log with restart verb fails" {
    write_log "[2026-05-03T12:00:00Z] systemctl restart airplanes-feed"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -ne 0 ]
}

@test "log with stop verb fails" {
    write_log "[2026-05-03T12:00:00Z] systemctl stop airplanes-feed"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -ne 0 ]
}

@test "log with kill verb fails" {
    write_log "[2026-05-03T12:00:00Z] systemctl kill airplanes-feed"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -ne 0 ]
}

@test "log with only enable lines passes and writes fingerprint" {
    write_log \
        "[2026-05-03T12:00:00Z] systemctl enable airplanes-feed" \
        "[2026-05-03T12:00:01Z] systemctl enable airplanes-mlat"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -eq 0 ]
    [ -f "$FINGERPRINT" ]
    grep -q 'invocations=2' "$FINGERPRINT"
    grep -q 'enables=2' "$FINGERPRINT"
}

@test "log with mixed enable + read-only verbs passes; fingerprint counts only enables" {
    write_log \
        "[2026-05-03T12:00:00Z] systemctl enable airplanes-feed" \
        "[2026-05-03T12:00:01Z] systemctl cat airplanes-feed" \
        "[2026-05-03T12:00:02Z] systemctl show airplanes-feed"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -eq 0 ]
    [ -f "$FINGERPRINT" ]
    grep -q 'invocations=3' "$FINGERPRINT"
    grep -q 'enables=1' "$FINGERPRINT"
}

@test "fingerprint format matches expected schema" {
    write_log "[2026-05-03T12:00:00Z] systemctl enable airplanes-feed"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -eq 0 ]
    grep -E -q '^invocations=[0-9]+ enables=[0-9]+ ts=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$FINGERPRINT"
}

@test "verb regex does not flag hyphenated unit names containing forbidden words" {
    write_log \
        "[2026-05-03T12:00:00Z] systemctl enable foo-stop.service" \
        "[2026-05-03T12:00:01Z] systemctl enable bar-restart-monitor.service"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -eq 0 ]
    [ -f "$FINGERPRINT" ]
    grep -q 'enables=2' "$FINGERPRINT"
}

@test "ROOTFS_DIR argument missing fails (set -u)" {
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "log with allowlisted restart (tar1090) passes" {
    write_log \
        "[2026-05-03T12:00:00Z] systemctl enable readsb.service" \
        "[2026-05-03T12:00:01Z] systemctl restart tar1090.service"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -eq 0 ]
    [ -f "$FINGERPRINT" ]
}

@test "log with allowlisted restart (graphs1090) passes" {
    write_log "[2026-05-03T12:00:00Z] systemctl restart graphs1090.service"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -eq 0 ]
}

@test "log with allowlisted restart (collectd) passes" {
    write_log "[2026-05-03T12:00:00Z] systemctl restart collectd.service"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -eq 0 ]
}

@test "log with allowlisted restart (lighttpd) passes" {
    write_log "[2026-05-03T12:00:00Z] systemctl restart lighttpd.service"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -eq 0 ]
}

@test "log with non-allowlisted restart (ssh) still fails" {
    write_log "[2026-05-03T12:00:00Z] systemctl restart ssh.service"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -ne 0 ]
}

@test "log with non-allowlisted restart (readsb) still fails" {
    write_log "[2026-05-03T12:00:00Z] systemctl restart readsb.service"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -ne 0 ]
}

@test "log mixing allowlisted and forbidden lines fails on the forbidden one" {
    write_log \
        "[2026-05-03T12:00:00Z] systemctl restart tar1090.service" \
        "[2026-05-03T12:00:01Z] systemctl restart airplanes-feed.service"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -ne 0 ]
}

@test "log with allowlisted bare unit name (no .service suffix) passes" {
    # Upstream tar1090/graphs1090 install scripts call systemctl with bare
    # unit names: `systemctl restart tar1090` rather than `tar1090.service`.
    write_log \
        "[2026-05-03T12:00:00Z] systemctl stop tar1090" \
        "[2026-05-03T12:00:01Z] systemctl restart collectd" \
        "[2026-05-03T12:00:02Z] systemctl restart lighttpd" \
        "[2026-05-03T12:00:03Z] systemctl restart graphs1090"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -eq 0 ]
}

@test "bare-name allowlist still rejects non-allowlisted bare names" {
    write_log "[2026-05-03T12:00:00Z] systemctl restart ssh"
    run bash "$SCRIPT" "$ROOT"
    [ "$status" -ne 0 ]
}
