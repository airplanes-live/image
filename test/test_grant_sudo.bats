#!/usr/bin/env bats

# Tests for /usr/local/sbin/airplanes-grant-sudo. Exercises the script
# end-to-end with PASSWD_FILE / DONE_MARKER / SUDOERS_DIR / VISUDO_BIN
# redirected into a per-test tmpdir. The script is invoked as a child
# `bash` so its `main "$@"` runs naturally.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/06c-grant-sudo/files/usr/local/sbin/airplanes-grant-sudo"
    TMP="$(mktemp -d)"
    export PASSWD_FILE="$TMP/passwd"
    export DONE_MARKER="$TMP/var/lib/airplanes/grant-sudo-done"
    export SUDOERS_DIR="$TMP/sudoers.d"
    export VISUDO_BIN="$TMP/bin/visudo"
    mkdir -p "$SUDOERS_DIR" "$TMP/bin" "$(dirname "$DONE_MARKER")"

    # Default fake visudo: accept anything. Tests that want to exercise the
    # rejection path overwrite this in the test body.
    cat >"$VISUDO_BIN" <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "$VISUDO_BIN"
}

teardown() { rm -rf "$TMP"; }

write_passwd() { printf '%s\n' "$@" >"$PASSWD_FILE"; }

# ---- happy-path -----------------------------------------------------------

@test "grants sudo to a single human user" {
    write_passwd \
        "root:x:0:0:root:/root:/bin/bash" \
        "airplanes:x:1001:1001::/home/airplanes:/bin/bash"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$SUDOERS_DIR/099_airplanes-sudo-airplanes" ]
    grep -qE '^airplanes ALL=\(ALL:ALL\) NOPASSWD: ALL$' "$SUDOERS_DIR/099_airplanes-sudo-airplanes"
}

@test "writes marker on success" {
    write_passwd "airplanes:x:1001:1001::/home/airplanes:/bin/bash"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$DONE_MARKER" ]
}

@test "grant file gets mode 0440" {
    write_passwd "airplanes:x:1001:1001::/home/airplanes:/bin/bash"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    perms="$(stat -c '%a' "$SUDOERS_DIR/099_airplanes-sudo-airplanes")"
    [ "$perms" = "440" ]
}

@test "grants both pi and a custom user when both exist" {
    # pi-gen ships a stock pi user (UID 1000, /bin/bash, --disabled-login);
    # rpi-imager creates a second human user (e.g. airplanes at UID 1001).
    # We grant sudo to both — pi's disabled-login state makes the grant
    # harmless, and an operator who re-enables pi gets sudo immediately.
    write_passwd \
        "pi:x:1000:1000:,,,:/home/pi:/bin/bash" \
        "airplanes:x:1001:1001::/home/airplanes:/bin/bash"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$SUDOERS_DIR/099_airplanes-sudo-pi" ]
    [ -f "$SUDOERS_DIR/099_airplanes-sudo-airplanes" ]
}

# ---- skip rules -----------------------------------------------------------

@test "skips system users (UID < 1000)" {
    write_passwd \
        "root:x:0:0:root:/root:/bin/bash" \
        "daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin" \
        "airplanes-feed:x:991:991::/:/usr/sbin/nologin"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$SUDOERS_DIR/099_airplanes-sudo-root" ]
    [ ! -f "$SUDOERS_DIR/099_airplanes-sudo-daemon" ]
    [ ! -f "$SUDOERS_DIR/099_airplanes-sudo-airplanes-feed" ]
}

@test "skips users with nologin / false shells" {
    write_passwd \
        "fakehuman:x:1001:1001::/:/usr/sbin/nologin" \
        "alsofake:x:1002:1002::/:/bin/false"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$SUDOERS_DIR/099_airplanes-sudo-fakehuman" ]
    [ ! -f "$SUDOERS_DIR/099_airplanes-sudo-alsofake" ]
}

@test "skips nobody (UID 65534)" {
    write_passwd "nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$SUDOERS_DIR/099_airplanes-sudo-nobody" ]
}

@test "skips explicit service-user names even if they fit the UID/shell gate" {
    # Defense-in-depth: if a future packaging change moves a service user
    # into the human UID range with a login shell, the explicit name list
    # still excludes them.
    write_passwd \
        "airplanes-feed:x:1001:1001::/:/bin/bash" \
        "airplanes-webconfig:x:1002:1002::/:/bin/bash" \
        "readsb:x:1003:1003::/:/bin/bash" \
        "darken:x:1004:1004::/:/bin/bash"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$SUDOERS_DIR/099_airplanes-sudo-darken" ]
    [ ! -f "$SUDOERS_DIR/099_airplanes-sudo-airplanes-feed" ]
    [ ! -f "$SUDOERS_DIR/099_airplanes-sudo-airplanes-webconfig" ]
    [ ! -f "$SUDOERS_DIR/099_airplanes-sudo-readsb" ]
}

@test "does NOT skip pi (operators may pick 'pi' as their rpi-imager username)" {
    write_passwd "pi:x:1000:1000:,,,:/home/pi:/bin/bash"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$SUDOERS_DIR/099_airplanes-sudo-pi" ]
}

# ---- idempotency / re-run -------------------------------------------------

@test "existing grant file is left untouched; marker still written" {
    write_passwd "airplanes:x:1001:1001::/home/airplanes:/bin/bash"
    printf 'preserve me\n' >"$SUDOERS_DIR/099_airplanes-sudo-airplanes"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$SUDOERS_DIR/099_airplanes-sudo-airplanes")" = "preserve me" ]
    [ -f "$DONE_MARKER" ]
}

# ---- failure semantics ----------------------------------------------------

@test "visudo rejection leaves no grant file and exits non-zero" {
    cat >"$VISUDO_BIN" <<'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$VISUDO_BIN"
    write_passwd "airplanes:x:1001:1001::/home/airplanes:/bin/bash"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [ ! -f "$SUDOERS_DIR/099_airplanes-sudo-airplanes" ]
    [ ! -f "$DONE_MARKER" ]
}

@test "partial failure: other users still processed, no marker written" {
    # Stub visudo to reject the file when it contains baduser's grant, accept
    # everything else. The script processes users in /etc/passwd order, so
    # alice + bob still get their grants while baduser doesn't.
    cat >"$VISUDO_BIN" <<'STUB'
#!/bin/bash
# argv: -cf <path>
if grep -q '^baduser ' "$2"; then
    exit 1
fi
exit 0
STUB
    chmod +x "$VISUDO_BIN"
    write_passwd \
        "alice:x:1001:1001::/home/alice:/bin/bash" \
        "baduser:x:1002:1002::/home/baduser:/bin/bash" \
        "bob:x:1003:1003::/home/bob:/bin/bash"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [ -f "$SUDOERS_DIR/099_airplanes-sudo-alice" ]
    [ ! -f "$SUDOERS_DIR/099_airplanes-sudo-baduser" ]
    [ -f "$SUDOERS_DIR/099_airplanes-sudo-bob" ]
    [ ! -f "$DONE_MARKER" ]
}

@test "no human users at all: marker still written, no grant files" {
    write_passwd \
        "root:x:0:0:root:/root:/bin/bash" \
        "nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$DONE_MARKER" ]
    # Sanity: no 099_ file written.
    [ -z "$(find "$SUDOERS_DIR" -maxdepth 1 -name '099_*' -print -quit)" ]
}

# ---- end-to-end against the real visudo (skip if unavailable) -------------

@test "real visudo accepts the script's output shape" {
    if ! command -v visudo >/dev/null 2>&1; then
        skip "visudo not installed on this runner"
    fi
    VISUDO_BIN="$(command -v visudo)" run bash "$SCRIPT" <<<""
    # The above wouldn't pass /etc/passwd through; re-run properly.
    write_passwd "airplanes:x:1001:1001::/home/airplanes:/bin/bash"
    VISUDO_BIN="$(command -v visudo)" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    visudo -cf "$SUDOERS_DIR/099_airplanes-sudo-airplanes"
}
