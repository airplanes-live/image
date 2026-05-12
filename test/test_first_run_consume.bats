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
#
# Scaffold-fixture choice: tests below use FEED_HOST=mybackend.local as the
# canonical "valid allowlisted key with an observable feed.env effect" so
# happy-path assertions can grep feed.env for the derived MLATSERVER/TARGET.
# HOSTNAME is the canonical "valid non-merge key" (it's applied to /etc/
# hostname, never to feed.env).

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/06-firstboot/files/usr/local/sbin/airplanes-first-run"
    export APL_WIFI_LIB_DIR="$BATS_TEST_DIRNAME/../stage-airplanes/05-install-webconfig/files/usr/local/lib/airplanes"
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

    # main() can trigger apply_hostname when BOOT_CFG carries HOSTNAME.
    # apply_hostname calls `hostnamectl set-hostname` + `hostname` against
    # the host; the stubs intercept those calls so the bats run can't
    # rename the developer's machine. Must load before sourcing the script.
    # shellcheck source=lib/host-runtime-stubs.sh
    source "$BATS_TEST_DIRNAME/lib/host-runtime-stubs.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT"
    BOOT_CFG=()
    BOOT_CFG_ERRORS=()
    reset_host_runtime_stubs
}

teardown() { rm -rf "$TMP"; }

write_cfg() { printf '%s\n' "$@" > "$BOOT_CONFIG"; }

# ---- happy-path cases ------------------------------------------------------

@test "01: successful apply renames .txt -> .applied.txt, no .error.txt" {
    write_cfg \
        "HOSTNAME=test-feeder" \
        "FEED_HOST=mybackend.local"
    run main
    [ "$status" -eq 0 ]
    [ ! -f "$BOOT_CONFIG" ]
    [ -f "$APPLIED_CONFIG" ]
    [ ! -f "$ERROR_FILE" ]
    [ -f "$FEED_ENV" ]
    # FEED_HOST is synthetic — it must NOT leak into feed.env. The derived
    # MLATSERVER and TARGET land there instead.
    ! grep -q '^FEED_HOST=' "$FEED_ENV"
    grep -q '^MLATSERVER="mybackend.local:31090"$' "$FEED_ENV"
    grep -q '^TARGET="--net-connector mybackend.local,30004,beast_reduce_plus_out"$' "$FEED_ENV"
    # HOSTNAME is synthetic — applied to /etc/hostname, not feed.env.
    ! grep -q '^HOSTNAME=' "$FEED_ENV"
    grep -qF 'test-feeder' "$HOSTNAME_FILE"
}

@test "02: successful apply clears stale .error.txt from a prior run" {
    write_cfg "FEED_HOST=mybackend.local"
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
    write_cfg "FEED_HOST=otherbackend.local"
    run main
    [ "$status" -eq 0 ]
    [ ! -f "$BOOT_CONFIG" ]
    [ -f "$APPLIED_CONFIG" ]
    # .applied.txt should now contain the new content, not the old
    grep -q '^FEED_HOST=otherbackend.local$' "$APPLIED_CONFIG"
    ! grep -q 'old content' "$APPLIED_CONFIG"
}

# ---- failure-path cases (single error) -------------------------------------

@test "07: invalid HOSTNAME leaves .txt in place, writes .error.txt, applies other keys" {
    write_cfg "FEED_HOST=mybackend.local" "HOSTNAME=foo.bar"
    run main
    [ "$status" -eq 0 ]
    [ -f "$BOOT_CONFIG" ]
    [ ! -f "$APPLIED_CONFIG" ]
    [ -f "$ERROR_FILE" ]
    grep -q 'HOSTNAME' "$ERROR_FILE"
    # Valid key still got merged into feed.env via expand_feed_host.
    grep -q '^MLATSERVER="mybackend.local:31090"$' "$FEED_ENV"
}

@test "08: invalid FEED_HOST leaves .txt in place, writes .error.txt" {
    # Space + semicolon: parse-time metachar reject doesn't catch these
    # (they're not in the metachar set), but expand_feed_host's regex does.
    write_cfg 'FEED_HOST=evil host;rm'
    run main
    [ "$status" -eq 0 ]
    [ -f "$BOOT_CONFIG" ]
    [ -f "$ERROR_FILE" ]
    grep -q 'FEED_HOST' "$ERROR_FILE"
}

@test "09: UAT_INPUT (non-allowlisted) is rejected with webconfig guidance" {
    # UAT_INPUT moves to webconfig per configspec.go WriteKeys; the boot
    # config rejects it with a "use webconfig UI" message.
    write_cfg 'UAT_INPUT=127.0.0.1:30978'
    run main
    [ "$status" -eq 0 ]
    [ -f "$BOOT_CONFIG" ]
    [ -f "$ERROR_FILE" ]
    grep -q 'UAT_INPUT' "$ERROR_FILE"
    grep -q 'webconfig UI' "$ERROR_FILE"
}

@test "10: malformed line (no '=') leaves .txt in place, writes .error.txt; valid key still merges" {
    write_cfg "FEED_HOST=mybackend.local" "this is not a key=value pair without ="
    run main
    [ "$status" -eq 0 ]
    [ -f "$BOOT_CONFIG" ]
    [ -f "$ERROR_FILE" ]
    grep -qE 'line 2:.*malformed' "$ERROR_FILE"
    # Valid key still got merged — derived endpoints land in feed.env even
    # when the source file stays pending due to other errors.
    grep -q '^MLATSERVER="mybackend.local:31090"$' "$FEED_ENV"
}

@test "11: shell-metachar in allowlisted HOSTNAME rejected; .error.txt names the key, no value leak" {
    # HOSTNAME is allowlisted (passes the allowlist gate), so the parse-time
    # shell-metachar reject fires for it. Asserts the defense-in-depth path:
    # value is rejected, key is named, the metachar payload doesn't leak
    # into airplanes-config.error.txt.
    write_cfg 'HOSTNAME=$(rm -rf /)'
    run main
    [ "$status" -eq 0 ]
    [ -f "$BOOT_CONFIG" ]
    [ -f "$ERROR_FILE" ]
    grep -q 'HOSTNAME' "$ERROR_FILE"
    grep -q 'unsafe value' "$ERROR_FILE"
    # The shell-metachar payload should NOT appear verbatim in the error file.
    ! grep -q 'rm -rf' "$ERROR_FILE"
}

@test "12: preflight failure (read-only BOOT_CONFIG dir) returns without mutating feed.env" {
    write_cfg "FEED_HOST=mybackend.local"
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
    write_cfg "FEED_HOST=mybackend.local"
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

@test "14: multiple error categories in one run -> all appear as bullets in .error.txt" {
    # One of each error category:
    #   FEED_HOST  → valid, gets merged (MLATSERVER/TARGET in feed.env)
    #   HOSTNAME=foo.bar → allowlisted, invalid value (apply_hostname error)
    #   malformed line → parser error
    #   LATITUDE=51.5 → allowlist-rejected with "webconfig UI" message
    #   MLATSERVER=lab → allowlist-rejected with "feed.env" message
    write_cfg \
        "FEED_HOST=mybackend.local" \
        "HOSTNAME=foo.bar" \
        "this is malformed" \
        "LATITUDE=51.5" \
        "MLATSERVER=lab:31090"
    run main
    [ "$status" -eq 0 ]
    [ -f "$BOOT_CONFIG" ]
    [ -f "$ERROR_FILE" ]
    # Each error key appears in the file.
    grep -q 'HOSTNAME' "$ERROR_FILE"
    grep -qE 'malformed' "$ERROR_FILE"
    grep -q 'LATITUDE' "$ERROR_FILE"
    grep -q 'MLATSERVER' "$ERROR_FILE"
    # Category-specific guidance is present.
    grep -q 'webconfig UI' "$ERROR_FILE"
    grep -q 'feed.env' "$ERROR_FILE"
    # Header + format sanity.
    grep -q '^Status: error$' "$ERROR_FILE"
    grep -q '^Source: ' "$ERROR_FILE"
    grep -q '^Errors:$' "$ERROR_FILE"
    # Valid key (FEED_HOST) still applied even alongside errors.
    grep -q '^MLATSERVER="mybackend.local:31090"$' "$FEED_ENV"
}

@test "15: WIFI_PASS value never appears in .error.txt (key name only, no length)" {
    # WIFI_PASS too short -> validate_wifi_inputs rejects, drops WiFi config,
    # and records an error. The error message must name the key, not echo the
    # value or anything that could narrow the secret. The sentinel "HUNT22"
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
    write_cfg "HOSTNAME=foo.bar" "FEED_HOST=mybackend.local"
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
    write_cfg "HOSTNAME=valid-name" "FEED_HOST=mybackend.local"
    run main
    [ "$status" -eq 0 ]
    [ ! -f "$BOOT_CONFIG" ]
    [ -f "$APPLIED_CONFIG" ]
    [ ! -f "$ERROR_FILE" ]
}

@test "19: state — .txt + stale .applied.txt + stale .error.txt -> success clears .error" {
    printf 'old applied content\n' > "$APPLIED_CONFIG"
    printf 'old error content\n' > "$ERROR_FILE"
    write_cfg "FEED_HOST=mybackend.local"
    run main
    [ "$status" -eq 0 ]
    [ -f "$APPLIED_CONFIG" ]
    grep -q '^FEED_HOST=mybackend.local$' "$APPLIED_CONFIG"
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

# ---- mixed valid + allowlist-rejected (new contract) -----------------------

@test "22: FEED_HOST=valid + LATITUDE=51.5 -> endpoints merged, error recorded, source pending" {
    # Allowlist rejection of a stray key does NOT block the merge for other
    # valid keys in the same file. FEED_HOST's derived MLATSERVER/TARGET land
    # in feed.env on every retry, and the source file stays pending until
    # the user removes the stray LATITUDE line.
    write_cfg \
        "FEED_HOST=mybackend.local" \
        "LATITUDE=51.5"
    run main
    [ "$status" -eq 0 ]
    [ -f "$BOOT_CONFIG" ]
    [ ! -f "$APPLIED_CONFIG" ]
    [ -f "$ERROR_FILE" ]
    grep -q 'LATITUDE' "$ERROR_FILE"
    grep -q 'webconfig UI' "$ERROR_FILE"
    # FEED_HOST's derived endpoints DO land in feed.env even though the
    # source file stays pending.
    grep -q '^MLATSERVER="mybackend.local:31090"$' "$FEED_ENV"
    grep -q '^TARGET="--net-connector mybackend.local,30004,beast_reduce_plus_out"$' "$FEED_ENV"
}

@test "23: typoed WIFI_PASSWORD value never appears in .error.txt or stderr" {
    # The allowlist rejection path also handles WIFI_PASSWORD typos. The
    # rejection message must name the key and point at the three valid WIFI_*
    # keys without echoing the value — same secret-safe guarantee the
    # validate_wifi_inputs path gave for WIFI_PASS length violations.
    write_cfg \
        'WIFI_SSID="MyNet"' \
        'WIFI_PASSWORD="HUNTLEAK22"'
    output_combined="$(main 2>&1 || true)"
    [ -f "$ERROR_FILE" ]
    grep -q 'WIFI_PASSWORD' "$ERROR_FILE"
    grep -q 'WIFI_SSID' "$ERROR_FILE"
    grep -q 'WIFI_PASS' "$ERROR_FILE"
    # The literal value (or any non-trivial prefix) must not appear in either
    # the error file or the combined stdout/stderr.
    ! grep -q 'HUNTLEAK' "$ERROR_FILE"
    [[ "$output_combined" != *"HUNTLEAK"* ]]
}

@test "24: WIFI_PASSWORD typo + valid WIFI_SSID -> NO open-network keyfile written" {
    # Without this guard, a WIFI_PASSWORD typo would silently downgrade the
    # user's intended WPA SSID to an open-network keyfile (NM keyfile written
    # with ssid=... and NO [wifi-security] block). The user would then join an
    # attacker-spoofable open network instead of getting "WiFi doesn't work
    # until you fix the typo." consume_wifi_config drops _WIFI_* state on any
    # WIFI_* allowlist rejection — write_nm_keyfile becomes a no-op.
    write_cfg \
        'WIFI_SSID="MyNet"' \
        'WIFI_PASSWORD="hunter22-secret"'
    run main
    [ "$status" -eq 0 ]
    [ -f "$ERROR_FILE" ]
    # No keyfile at all — neither WPA nor open.
    [ ! -f "$WIFI_KEYFILE" ]
}
