#!/usr/bin/env bats

# Tests for the consume-and-rename behaviour of airplanes-first-run's main():
# on success, /boot/firmware/airplanes-config.txt is renamed to
# airplanes-config.applied.txt and any stale airplanes-config.error.txt is
# cleared; on failure, the source stays in place and airplanes-config.error.txt
# is written naming what to fix.
#
# These tests exercise main() end-to-end with the script's external paths
# (BOOT_CONFIG, FEED_ENV, LOCK_FILE, FEEDER_ID_FILE, CREATE_UUID,
# WIFI_KEYFILE_DIR, HOSTNAME_FILE, HOSTS_FILE) redirected to a per-test
# tmpdir. They DO NOT exercise systemd sandboxing (chroot tests can't —
# see test_first_run_unit.bats for the static unit-file lint that does).

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/06-firstboot/files/usr/local/sbin/airplanes-first-run"
    TMP="$(mktemp -d)"

    export BOOT_CONFIG="$TMP/firmware/airplanes-config.txt"
    export APPLIED_CONFIG="$TMP/firmware/airplanes-config.applied.txt"
    export ERROR_FILE="$TMP/firmware/airplanes-config.error.txt"
    export FEED_ENV="$TMP/etc/airplanes/feed.env"
    export LOCK_FILE="$TMP/run/feed-env.lock"
    export FEEDER_ID_FILE="$TMP/etc/airplanes/feeder-id"
    export CREATE_UUID="$TMP/nonexistent-create-uuid"
    export WIFI_KEYFILE_DIR="$TMP/nm-keyfiles"
    export WIFI_KEYFILE="$WIFI_KEYFILE_DIR/airplanes-config-wifi.nmconnection"
    export HOSTNAME_FILE="$TMP/hostname"
    export HOSTS_FILE="$TMP/hosts"

    mkdir -p \
        "$TMP/firmware" \
        "$TMP/etc/airplanes" \
        "$TMP/run" \
        "$WIFI_KEYFILE_DIR"
    # Pre-seed feeder-id so generate_feeder_id no-ops (we don't need it for
    # consume-rename tests, and avoiding create-uuid.sh keeps tests hermetic).
    printf '00000000-0000-0000-0000-000000000000\n' > "$FEEDER_ID_FILE"
    # Pre-seed hostname so apply_hostname's /etc/hosts probe has a current value.
    printf 'raspberrypi\n' > "$HOSTNAME_FILE"
    printf '127.0.1.1\traspberrypi\n' > "$HOSTS_FILE"

    # shellcheck source=/dev/null
    source "$SCRIPT"
    BOOT_CFG=()
    BOOT_CFG_ERRORS=()
}

teardown() { rm -rf "$TMP"; }

write_cfg() { printf '%s\n' "$@" > "$BOOT_CONFIG"; }

# ---- happy-path cases ------------------------------------------------------

@test "01: successful apply renames .txt -> .applied.txt, no .error.txt" {
    write_cfg \
        "LATITUDE=51.5" \
        "LONGITUDE=-0.1" \
        "MLAT_USER=test-feeder" \
        "MLAT_ENABLED=true"
    run main
    [ "$status" -eq 0 ]
    [ ! -f "$BOOT_CONFIG" ]
    [ -f "$APPLIED_CONFIG" ]
    [ ! -f "$ERROR_FILE" ]
    [ -f "$FEED_ENV" ]
    grep -q '^LATITUDE="51.5"$' "$FEED_ENV"
    grep -q '^MLAT_USER="test-feeder"$' "$FEED_ENV"
}

@test "02: successful apply clears stale .error.txt from a prior run" {
    write_cfg "LATITUDE=51.5"
    printf 'stale error from previous boot\n' > "$ERROR_FILE"
    run main
    [ "$status" -eq 0 ]
    [ -f "$APPLIED_CONFIG" ]
    [ ! -f "$ERROR_FILE" ]
}

@test "03: empty file is consumed cleanly (rename, no merge, no .error.txt)" {
    : > "$BOOT_CONFIG"
    : > "$FEED_ENV"
    run main
    [ "$status" -eq 0 ]
    [ ! -f "$BOOT_CONFIG" ]
    [ -f "$APPLIED_CONFIG" ]
    [ ! -f "$ERROR_FILE" ]
    # feed.env should be untouched (no keys to merge)
    [ ! -s "$FEED_ENV" ]
}

@test "04: comment-only file is consumed cleanly" {
    write_cfg "# only comments" "" "# more comments"
    run main
    [ "$status" -eq 0 ]
    [ ! -f "$BOOT_CONFIG" ]
    [ -f "$APPLIED_CONFIG" ]
    [ ! -f "$ERROR_FILE" ]
}

@test "05: no boot config at all (after consumption) is a no-op" {
    # Don't create $BOOT_CONFIG; only .applied.txt is present.
    : > "$APPLIED_CONFIG"
    run main
    [ "$status" -eq 0 ]
    [ ! -f "$BOOT_CONFIG" ]
    [ -f "$APPLIED_CONFIG" ]
    [ ! -f "$ERROR_FILE" ]
}

@test "06: fresh .txt over an existing .applied.txt re-applies and overwrites .applied" {
    printf 'old content\n' > "$APPLIED_CONFIG"
    write_cfg "LATITUDE=42.0"
    run main
    [ "$status" -eq 0 ]
    [ ! -f "$BOOT_CONFIG" ]
    [ -f "$APPLIED_CONFIG" ]
    # .applied.txt should now contain the new content, not the old
    grep -q '^LATITUDE=42.0$' "$APPLIED_CONFIG"
    ! grep -q 'old content' "$APPLIED_CONFIG"
}

# ---- failure-path cases (single error) -------------------------------------

@test "07: invalid HOSTNAME leaves .txt in place, writes .error.txt, applies other keys" {
    write_cfg "LATITUDE=51.5" "HOSTNAME=foo.bar"
    run main
    [ "$status" -eq 0 ]
    [ -f "$BOOT_CONFIG" ]
    [ ! -f "$APPLIED_CONFIG" ]
    [ -f "$ERROR_FILE" ]
    grep -q 'HOSTNAME' "$ERROR_FILE"
    # Valid key still got merged
    grep -q '^LATITUDE="51.5"$' "$FEED_ENV"
}

@test "08: invalid FEED_HOST leaves .txt in place, writes .error.txt" {
    write_cfg 'FEED_HOST=evil host;rm'
    run main
    [ "$status" -eq 0 ]
    [ -f "$BOOT_CONFIG" ]
    [ -f "$ERROR_FILE" ]
    grep -q 'FEED_HOST' "$ERROR_FILE"
}

@test "09: invalid UAT_INPUT leaves .txt in place, writes .error.txt" {
    write_cfg 'UAT_INPUT=10.0.0.5:30978'
    run main
    [ "$status" -eq 0 ]
    [ -f "$BOOT_CONFIG" ]
    [ -f "$ERROR_FILE" ]
    grep -q 'UAT_INPUT' "$ERROR_FILE"
}

@test "10: malformed line (no '=') leaves .txt in place, writes .error.txt" {
    write_cfg "LATITUDE=51.5" "this is not a key=value pair without ="
    run main
    [ "$status" -eq 0 ]
    [ -f "$BOOT_CONFIG" ]
    [ -f "$ERROR_FILE" ]
    grep -qE 'line 2:.*malformed' "$ERROR_FILE"
    # Valid key still got merged
    grep -q '^LATITUDE="51.5"$' "$FEED_ENV"
}

@test "11: shell-injection value rejected; .error.txt names the key, no value leak" {
    write_cfg 'EVIL=$(rm -rf /)'
    run main
    [ "$status" -eq 0 ]
    [ -f "$BOOT_CONFIG" ]
    [ -f "$ERROR_FILE" ]
    grep -q 'EVIL' "$ERROR_FILE"
    # The shell-metachar value should NOT appear verbatim in the error file.
    ! grep -q 'rm -rf' "$ERROR_FILE"
}

@test "12: preflight failure (read-only BOOT_CONFIG dir) returns without mutating feed.env" {
    write_cfg "LATITUDE=51.5"
    : > "$FEED_ENV"
    feed_env_before="$(stat -c %Y "$FEED_ENV")"
    sleep 1
    chmod 0555 "$TMP/firmware"
    run main
    chmod 0755 "$TMP/firmware"
    [ "$status" -eq 0 ]
    [ -f "$BOOT_CONFIG" ]
    # feed.env was not modified
    feed_env_after="$(stat -c %Y "$FEED_ENV")"
    [ "$feed_env_before" = "$feed_env_after" ]
    # And no .error.txt either (we couldn't write one to that dir anyway)
    [ ! -f "$ERROR_FILE" ]
}

@test "13: rename failure leaves .txt in place AND writes .error.txt with rename note" {
    write_cfg "LATITUDE=51.5"
    # Pre-create .applied.txt as a directory so mv -fT fails.
    # mv -fT refuses to replace a directory with a non-directory.
    mkdir -p "$APPLIED_CONFIG"
    run main
    [ "$status" -eq 0 ]
    [ -f "$BOOT_CONFIG" ]
    [ -f "$ERROR_FILE" ]
    grep -qi 'rename' "$ERROR_FILE"
    # Cleanup so teardown's rm -rf works.
    rmdir "$APPLIED_CONFIG" 2>/dev/null || true
}

# ---- multi-error and content cases -----------------------------------------

@test "14: multiple errors in one run -> all appear as bullets in .error.txt" {
    write_cfg \
        "LATITUDE=51.5" \
        "HOSTNAME=foo.bar" \
        "this is malformed" \
        'EVIL=$(badness)' \
        "UAT_INPUT=10.0.0.5:30978"
    run main
    [ "$status" -eq 0 ]
    [ -f "$BOOT_CONFIG" ]
    [ -f "$ERROR_FILE" ]
    # Each error key should appear in the file.
    grep -q 'HOSTNAME' "$ERROR_FILE"
    grep -qE 'malformed' "$ERROR_FILE"
    grep -q 'EVIL' "$ERROR_FILE"
    grep -q 'UAT_INPUT' "$ERROR_FILE"
    # Header + format sanity.
    grep -q '^Status: error$' "$ERROR_FILE"
    grep -q '^Source: ' "$ERROR_FILE"
    grep -q '^Errors:$' "$ERROR_FILE"
}

@test "15: WIFI_PASS value never appears in .error.txt (key name only, no length)" {
    # WIFI_PASS too short -> validate_wifi_inputs rejects, drops WiFi config,
    # and records an error. The error message must name the key, not echo the
    # value or anything that could narrow the secret. The sentinel "HUNTER22"
    # is the value-substring we assert does NOT leak.
    # 7-char PSK is below the 8-char WPA minimum -> rejected.
    write_cfg 'WIFI_SSID="MyNet"' 'WIFI_PASS="HUNT22X"'
    run main
    [ "$status" -eq 0 ]
    [ -f "$ERROR_FILE" ]
    grep -q 'WIFI_PASS' "$ERROR_FILE"
    # The literal value (or any non-trivial prefix) must not appear.
    ! grep -q 'HUNT22' "$ERROR_FILE"
}

@test "16: WIFI_SSID value never appears in .error.txt (only the key)" {
    # WIFI_SSID over 32 bytes -> validate_wifi_inputs rejects with key name only.
    write_cfg 'WIFI_SSID="This-SSID-Is-Way-Too-Long-For-WPA-Specification-Limit"'
    run main
    [ "$status" -eq 0 ]
    [ -f "$ERROR_FILE" ]
    grep -q 'WIFI_SSID' "$ERROR_FILE"
    # SSID value must not appear.
    ! grep -q 'This-SSID' "$ERROR_FILE"
}

@test "17: .error.txt format is stable and human-readable" {
    write_cfg "HOSTNAME=foo.bar"
    run main
    [ -f "$ERROR_FILE" ]
    # Sentinel lines we promise users.
    grep -qF 'airplanes.live first-run config was not fully applied.' "$ERROR_FILE"
    grep -qF "Fix the items below, keep the file named airplanes-config.txt, then reboot." "$ERROR_FILE"
    grep -qE '^- ' "$ERROR_FILE"
}

# ---- idempotency / state-machine cases -------------------------------------

@test "18: retry sequence: bad -> .error -> reboot no fix -> same .error -> fix -> .applied" {
    # Bad input.
    write_cfg "HOSTNAME=foo.bar" "LATITUDE=51.5"
    run main
    [ -f "$ERROR_FILE" ]
    err_first="$(cat "$ERROR_FILE")"

    # Second invocation with no edit — same .error.txt content.
    run main
    [ -f "$ERROR_FILE" ]
    err_second="$(cat "$ERROR_FILE")"
    [ "$err_first" = "$err_second" ]
    [ -f "$BOOT_CONFIG" ]

    # User fixes the typo and reboots.
    write_cfg "HOSTNAME=valid-name" "LATITUDE=51.5"
    run main
    [ "$status" -eq 0 ]
    [ ! -f "$BOOT_CONFIG" ]
    [ -f "$APPLIED_CONFIG" ]
    [ ! -f "$ERROR_FILE" ]
}

@test "19: state — .txt + stale .applied.txt + stale .error.txt -> success clears .error" {
    printf 'old applied content\n' > "$APPLIED_CONFIG"
    printf 'old error content\n' > "$ERROR_FILE"
    write_cfg "LATITUDE=51.5"
    run main
    [ "$status" -eq 0 ]
    [ -f "$APPLIED_CONFIG" ]
    grep -q '^LATITUDE=51.5$' "$APPLIED_CONFIG"
    ! grep -q 'old applied' "$APPLIED_CONFIG"
    [ ! -f "$ERROR_FILE" ]
}

@test "20: state — only stale .error.txt (no .txt) is left alone (unit no-ops)" {
    printf 'stale\n' > "$ERROR_FILE"
    run main
    [ "$status" -eq 0 ]
    # No source file → no consumption, no rewrite. Stale .error.txt stays.
    [ -f "$ERROR_FILE" ]
    [ ! -f "$BOOT_CONFIG" ]
    [ ! -f "$APPLIED_CONFIG" ]
}

# ---- WIFI_PASS leak defence (extra confidence) -----------------------------

@test "21: rejected WIFI_PASS — value does not appear in journal/log either" {
    # record_error calls log() which uses logger or echo to stderr. With a
    # too-short PSK (length 7, below the 8-char WPA-PSK minimum) we trigger
    # the rejection path and confirm the value never appears in stderr/stdout.
    write_cfg 'WIFI_SSID="MyNet"' 'WIFI_PASS="LEAKBA1"'
    output_combined="$(main 2>&1 || true)"
    [[ "$output_combined" != *"LEAKBA1"* ]]
}
