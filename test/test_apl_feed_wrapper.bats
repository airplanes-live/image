#!/usr/bin/env bats

# Tests for /usr/local/sbin/apl-feed — the image's auto-sudo wrapper around
# the feed-installed /usr/local/bin/apl-feed binary. Exercises the wrapper
# end-to-end with a stub `apl-feed` binary (APL_FEED_BIN env override), a
# stub `sudo`, and a PATH-stubbed `id` so we can simulate both root and
# non-root invocations. The script is invoked as a child `sh` so its
# top-level dispatch logic runs naturally.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/06d-cli-ergonomics/files/usr/local/sbin/apl-feed"
    TMP="$(mktemp -d)"
    STUB_BIN="$TMP/stubs"
    mkdir -p "$STUB_BIN"

    # Stub apl-feed binary: logs every invocation (one line per call, with
    # all argv after the program name) to $TMP/apl-feed.calls, echoes any
    # stdin to $TMP/apl-feed.stdin, and exits 0.
    cat >"$TMP/apl-feed-bin" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$APL_FEED_CALLS"
cat >"$APL_FEED_STDIN" 2>/dev/null || true
exit 0
STUB
    chmod +x "$TMP/apl-feed-bin"
    export APL_FEED_BIN="$TMP/apl-feed-bin"
    export APL_FEED_CALLS="$TMP/apl-feed.calls"
    export APL_FEED_STDIN="$TMP/apl-feed.stdin"
    : >"$APL_FEED_CALLS"
    : >"$APL_FEED_STDIN"

    # Default stubs on PATH: a non-root `id`, an allowing `sudo`, and an
    # always-succeeding `sudo -n -v` probe (handled inside the same stub).
    # Tests that need different behaviour overwrite these.
    cat >"$STUB_BIN/id" <<'STUB'
#!/bin/sh
[ "$1" = "-u" ] && { printf '1001\n'; exit 0; }
exec /usr/bin/id "$@"
STUB
    chmod +x "$STUB_BIN/id"

    # `sudo` stub: handles three call shapes used by the wrapper.
    #   sudo -n -v             -> exit per $TMP/sudo-probe.exit (default 0)
    #   sudo -n -- BIN args... -> log "sudo:" + remaining args, pass stdin
    cat >"$STUB_BIN/sudo" <<'STUB'
#!/bin/sh
if [ "$1" = "-n" ] && [ "$2" = "-v" ]; then
    rc=0
    [ -f "$SUDO_PROBE_EXIT_FILE" ] && rc="$(cat "$SUDO_PROBE_EXIT_FILE")"
    exit "$rc"
fi
if [ "$1" = "-n" ] && [ "$2" = "--" ]; then
    shift 2
    # First positional is the target binary; the rest is argv.
    bin="$1"; shift
    printf 'sudo: %s\n' "$*" >>"$APL_FEED_CALLS"
    cat >"$APL_FEED_STDIN" 2>/dev/null || true
    exit 0
fi
printf 'sudo: unexpected argv: %s\n' "$*" >&2
exit 99
STUB
    chmod +x "$STUB_BIN/sudo"
    export SUDO_PROBE_EXIT_FILE="$TMP/sudo-probe.exit"

    PATH="$STUB_BIN:$PATH"
    export PATH
}

teardown() { rm -rf "$TMP"; }

# Helper: the calls log content as one big string.
calls() { cat "$APL_FEED_CALLS"; }

# ---- root short-circuit ---------------------------------------------------

@test "root: privileged subcommand calls binary directly, no sudo" {
    cat >"$STUB_BIN/id" <<'STUB'
#!/bin/sh
[ "$1" = "-u" ] && { printf '0\n'; exit 0; }
exec /usr/bin/id "$@"
STUB
    chmod +x "$STUB_BIN/id"

    run sh "$SCRIPT" mlat enable
    [ "$status" -eq 0 ]
    [ "$(calls)" = "mlat enable" ]
}

@test "root: read-only subcommand also calls binary directly" {
    cat >"$STUB_BIN/id" <<'STUB'
#!/bin/sh
[ "$1" = "-u" ] && { printf '0\n'; exit 0; }
exec /usr/bin/id "$@"
STUB
    chmod +x "$STUB_BIN/id"

    run sh "$SCRIPT" schema --json
    [ "$status" -eq 0 ]
    [ "$(calls)" = "schema --json" ]
}

# ---- read-only allowlist (non-root) --------------------------------------

@test "non-root: bare invocation skips sudo" {
    run sh "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(calls)" = "" ]   # $* is empty so the log line is empty
    # The binary was called (file exists and is empty-after-write).
    [ -f "$APL_FEED_CALLS" ]
}

@test "non-root: -h skips sudo" {
    run sh "$SCRIPT" -h
    [ "$status" -eq 0 ]
    [ "$(calls)" = "-h" ]
}

@test "non-root: --help skips sudo" {
    run sh "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [ "$(calls)" = "--help" ]
}

@test "non-root: schema skips sudo" {
    run sh "$SCRIPT" schema
    [ "$status" -eq 0 ]
    [ "$(calls)" = "schema" ]
}

@test "non-root: schema --json skips sudo" {
    run sh "$SCRIPT" schema --json
    [ "$status" -eq 0 ]
    [ "$(calls)" = "schema --json" ]
}

# ---- sudo path (non-root) -------------------------------------------------

@test "non-root: status goes via sudo (NOT read-only — touches claim secret)" {
    run sh "$SCRIPT" status
    [ "$status" -eq 0 ]
    [ "$(calls)" = "sudo: status" ]
}

@test "non-root: id set goes via sudo" {
    run sh "$SCRIPT" id set abc-123
    [ "$status" -eq 0 ]
    [ "$(calls)" = "sudo: id set abc-123" ]
}

@test "non-root: claim register goes via sudo" {
    run sh "$SCRIPT" claim register
    [ "$status" -eq 0 ]
    [ "$(calls)" = "sudo: claim register" ]
}

@test "non-root: 978 enable goes via sudo" {
    run sh "$SCRIPT" 978 enable
    [ "$status" -eq 0 ]
    [ "$(calls)" = "sudo: 978 enable" ]
}

@test "non-root: config sync goes via sudo" {
    run sh "$SCRIPT" config sync
    [ "$status" -eq 0 ]
    [ "$(calls)" = "sudo: config sync" ]
}

@test "non-root: backup goes via sudo" {
    run sh "$SCRIPT" backup
    [ "$status" -eq 0 ]
    [ "$(calls)" = "sudo: backup" ]
}

@test "non-root: restore goes via sudo" {
    run sh "$SCRIPT" restore
    [ "$status" -eq 0 ]
    [ "$(calls)" = "sudo: restore" ]
}

@test "non-root: apply --json goes via sudo" {
    run sh "$SCRIPT" apply --json
    [ "$status" -eq 0 ]
    [ "$(calls)" = "sudo: apply --json" ]
}

@test "non-root: mlat enable goes via sudo" {
    run sh "$SCRIPT" mlat enable
    [ "$status" -eq 0 ]
    [ "$(calls)" = "sudo: mlat enable" ]
}

@test "non-root: diagnostics enable goes via sudo" {
    run sh "$SCRIPT" diagnostics enable
    [ "$status" -eq 0 ]
    [ "$(calls)" = "sudo: diagnostics enable" ]
}

@test "non-root: import goes via sudo" {
    run sh "$SCRIPT" import
    [ "$status" -eq 0 ]
    [ "$(calls)" = "sudo: import" ]
}

# ---- stdin survival through sudo -----------------------------------------

@test "non-root: apply --json stdin survives the sudo hop" {
    run sh -c 'printf "%s" "{\"feed.env.MLAT_ENABLED\":\"true\"}" | sh "$0" apply --json' "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$APL_FEED_STDIN")" = '{"feed.env.MLAT_ENABLED":"true"}' ]
}

@test "non-root: id set stdin survives the sudo hop" {
    run sh -c 'printf "extra-bytes" | sh "$0" id set abc-123' "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$APL_FEED_STDIN")" = "extra-bytes" ]
}

@test "non-root: claim set stdin survives the sudo hop" {
    run sh -c 'printf "secret-value" | sh "$0" claim set' "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$APL_FEED_STDIN")" = "secret-value" ]
}

@test "non-root: restore --uuid stdin survives the sudo hop" {
    run sh -c 'printf "backup-blob" | sh "$0" restore --uuid xyz' "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$APL_FEED_STDIN")" = "backup-blob" ]
}

# ---- sudo unavailable -----------------------------------------------------

@test "non-root: sudo -n -v failure emits targeted error and exits non-zero" {
    printf '1\n' >"$SUDO_PROBE_EXIT_FILE"
    run sh "$SCRIPT" mlat enable
    [ "$status" -ne 0 ]
    [[ "$output" == *"passwordless sudo not yet available"* ]]
    [[ "$output" == *"airplanes-grant-sudo.service"* ]]
    [[ "$output" == *"sudo apl-feed"* ]]   # explicit escape-hatch hint
    # And the binary was NOT called.
    [ "$(calls)" = "" ]
}
