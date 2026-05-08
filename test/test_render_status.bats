#!/usr/bin/env bats

# Unit tests for stage-airplanes/06b-console-dashboard/files/usr/local/lib/airplanes/render-status.
# Sources the script for direct access to helpers; the BASH_SOURCE guard at
# the bottom of render-status suppresses dispatcher execution on source.

bats_require_minimum_version 1.5.0

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/06b-console-dashboard/files/usr/local/lib/airplanes/render-status"
    LOGO="$BATS_TEST_DIRNAME/../stage-airplanes/06b-console-dashboard/files/usr/local/share/airplanes/logo.txt"
    BANNER="$BATS_TEST_DIRNAME/../stage-airplanes/06b-console-dashboard/files/usr/local/share/airplanes/banner.txt"
    TMP="$(mktemp -d)"

    # All PATHS_* default to /nonexistent so an un-overridden test gets the
    # "all sources missing" baseline. Individual tests then point a single
    # PATHS_* at a fixture.
    export PATHS_FEEDER_ID="$TMP/nx-feeder-id"
    export PATHS_RELEASE_CHANNEL="$TMP/nx-channel"
    export PATHS_MANIFEST="$TMP/nx-manifest"
    export PATHS_FEED_ENV="$TMP/nx-feed-env"
    export PATHS_CLAIM_SECRET="$TMP/nx-claim-secret"
    export PATHS_CLAIM_PENDING="$TMP/nx-claim-pending"
    export PATHS_CLAIM_VERSION="$TMP/nx-claim-version"
    export PATHS_AIRCRAFT_JSON="$TMP/nx-aircraft"
    export PATHS_THERMAL="$TMP/nx-thermal"
    export PATHS_LOGO="$LOGO"
    export PATHS_BANNER="$BANNER"
    # State-file paths default to non-existent so the defensive
    # `airplanes_read_state() { return 1; }` stub kicks in. Tests that
    # exercise the state-file path call `setup_mlat_state_test_env` to
    # install a working stub and point PATHS_STATE_FILE_MLAT at a fixture.
    export PATHS_STATE_FILE_MLAT="$TMP/nx-mlat-state"
    export PATHS_STATE_FILE_FEED="$TMP/nx-feed-state"
    export PATHS_STATE_READER_LIB="$TMP/nx-state-reader-lib"
    export TERM=dumb  # disable color so assertions match plain text

    # shellcheck source=/dev/null
    source "$SCRIPT"
}

teardown() { rm -rf "$TMP"; }

# Strip ANSI SGR escapes so width / substring assertions can match what the
# user actually sees (color escapes don't take display columns).
strip_ansi() {
    sed -E 's/'$'\x1b''\[[0-9;]*m//g'
}

# Display-cell width of the longest line in a stream. UTF-8 aware via
# C.UTF-8 + bash ${#var}; serves the layout-width assertions below.
max_display_width() {
    local LC_ALL=C.UTF-8
    local line max=0
    while IFS= read -r line; do
        (( ${#line} > max )) && max=${#line}
    done
    printf '%s' "$max"
}

# ---- _use_color ------------------------------------------------------------

@test "use_color: TERM=dumb returns non-zero (color disabled)" {
    run ! env TERM=dumb bash -c "source $SCRIPT && _use_color"
}

@test "use_color: TERM unset returns non-zero (color disabled)" {
    run ! env -u TERM bash -c "source $SCRIPT && _use_color"
}

# ---- sanitize --------------------------------------------------------------

@test "sanitize: drops control bytes, keeps printable ASCII" {
    out="$(sanitize $'foo\x07bar\x1b[31m' 64)"
    [ "$out" = "foobar[31m" ]
}

@test "sanitize: clamps at maxlen" {
    out="$(sanitize "abcdefghij" 4)"
    [ "$out" = "abcd" ]
}

# ---- read_feeder_id --------------------------------------------------------

@test "read_feeder_id: returns empty when file absent" {
    out="$(read_feeder_id)"
    [ -z "$out" ]
}

@test "read_feeder_id: returns trimmed UUID" {
    printf 'abc12345-1234-1234-1234-1234567890ab\n' > "$PATHS_FEEDER_ID"
    out="$(read_feeder_id)"
    [ "$out" = "abc12345-1234-1234-1234-1234567890ab" ]
}

# ---- read_feed_env_var -----------------------------------------------------

@test "read_feed_env_var: LATITUDE unquoted" {
    printf 'LATITUDE=48.123\n' > "$PATHS_FEED_ENV"
    [ "$(read_feed_env_var LATITUDE)" = "48.123" ]
}

@test "read_feed_env_var: LATITUDE quoted" {
    printf 'LATITUDE="48.123"\n' > "$PATHS_FEED_ENV"
    [ "$(read_feed_env_var LATITUDE)" = "48.123" ]
}

@test "read_feed_env_var: LATITUDE=0 returns 0" {
    printf 'LATITUDE=0\n' > "$PATHS_FEED_ENV"
    [ "$(read_feed_env_var LATITUDE)" = "0" ]
}

@test "read_feed_env_var: empty value returns empty" {
    printf 'LATITUDE=\n' > "$PATHS_FEED_ENV"
    [ -z "$(read_feed_env_var LATITUDE)" ]
}

@test "read_feed_env_var: unwhitelisted key returns empty" {
    printf 'TARGET=foo\n' > "$PATHS_FEED_ENV"
    [ -z "$(read_feed_env_var TARGET)" ]
}

@test "read_feed_env_var: USER=changeme is captured" {
    printf 'USER=changeme\n' > "$PATHS_FEED_ENV"
    [ "$(read_feed_env_var USER)" = "changeme" ]
}

@test "read_feed_env_var: duplicate keys -> last wins (matches Go feedenv)" {
    cat > "$PATHS_FEED_ENV" <<'EOF'
LATITUDE=0
LATITUDE=48.5
EOF
    [ "$(read_feed_env_var LATITUDE)" = "48.5" ]
}

# ---- claim_state -----------------------------------------------------------

@test "claim_state: no files -> unclaimed" {
    [ "$(claim_state)" = "unclaimed" ]
}

@test "claim_state: secret only -> secret-saved" {
    : > "$PATHS_CLAIM_SECRET"
    [ "$(claim_state)" = "secret-saved" ]
}

@test "claim_state: secret + version -> registered (vN)" {
    : > "$PATHS_CLAIM_SECRET"
    printf '7\n' > "$PATHS_CLAIM_VERSION"
    [ "$(claim_state)" = "registered (v7)" ]
}

@test "claim_state: pending + final -> rotation-pending" {
    : > "$PATHS_CLAIM_SECRET"
    printf '7\n' > "$PATHS_CLAIM_VERSION"
    : > "$PATHS_CLAIM_PENDING"
    [ "$(claim_state)" = "rotation-pending" ]
}

@test "claim_state: pending alone (no final) -> registration-pending" {
    : > "$PATHS_CLAIM_PENDING"
    [ "$(claim_state)" = "registration-pending" ]
}

@test "claim_state: NEVER reads claim secret contents" {
    # If claim_state ever cracks open the secret file, this will be in the
    # function's trace. We assert by writing a unique sentinel and verifying
    # the rendered state never contains it.
    printf 'SECRET-SENTINEL-DO-NOT-LEAK-A1B2C3D4E5F6\n' > "$PATHS_CLAIM_SECRET"
    out="$(claim_state)"
    [[ "$out" != *SECRET-SENTINEL* ]]
    [[ "$out" != *A1B2C3D4* ]]
}

# ---- mlat_config_state (state-file-driven, replaces mlat_disabled_by_config) ----

# Helper: write a fixture state file under the test root.
write_mlat_state() {
    # write_mlat_state <decision> <reason>
    local decision="$1" reason="$2"
    mkdir -p "$(dirname "$PATHS_STATE_FILE_MLAT")"
    {
        printf 'schema_version=1\n'
        printf 'service=airplanes-mlat\n'
        printf 'state=%s\n' "$decision"
        printf 'reason=%s\n' "$reason"
    } > "$PATHS_STATE_FILE_MLAT"
}

# Helper: stub airplanes_read_state to read from PATHS_STATE_FILE_MLAT
# in test mode (mirrors the production lib's contract closely enough).
# Tests that don't want the stub call `unset_state_reader_stub` to
# return to the source-time stub (always returns 1).
install_state_reader_stub() {
    airplanes_read_state() {
        local file="$1" key="$2"
        [[ -f "$file" && -r "$file" ]] || return 1
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
        local first=1 line value
        while IFS= read -r line; do
            if (( first )); then
                first=0
                [[ "$line" == 'schema_version=1' ]] || return 1
                continue
            fi
            case "$line" in
                "${key}="*)
                    value="${line#"${key}="}"
                    printf '%s' "$value"
                    return 0
                    ;;
            esac
        done < "$file"
        return 1
    }
}

# Helper: stub systemctl to return chosen ActiveState / ExecMainStatus.
stub_systemctl() {
    local active_state="$1" exec_main_status="${2:-0}"
    cat > "$TMP/systemctl" <<STUB
#!/usr/bin/env bash
case "\$1 \$2 \$3" in
    "show --property=ActiveState --value") shift 3; printf '%s\n' '$active_state'; exit 0 ;;
    "show --property=ExecMainStatus --value") shift 3; printf '%s\n' '$exec_main_status'; exit 0 ;;
esac
case "\$1" in
    is-enabled) shift; printf 'enabled\n'; exit 0 ;;
    is-active) [[ '$active_state' == 'active' ]] && exit 0 || exit 3 ;;
esac
exit 0
STUB
    chmod +x "$TMP/systemctl"
    PATH="$TMP:$PATH"
}

# Test setup amendment: each test overrides the state-reader source
# path to a non-existent file (causing the defensive stub to kick in)
# OR calls install_state_reader_stub for a working stub.
setup_mlat_state_test_env() {
    install_state_reader_stub
    PATHS_STATE_FILE_MLAT="$TMP/run/airplanes-mlat/state"
}

@test "mlat_config_state: active + state file present + state=enabled,reason=ok" {
    setup_mlat_state_test_env
    write_mlat_state enabled ok
    run mlat_config_state active
    [ "$status" -eq 0 ]
    [ "$output" = 'enabled ok' ]
}

@test "mlat_config_state: active + state=disabled,reason=mlat_enabled_false" {
    setup_mlat_state_test_env
    write_mlat_state disabled mlat_enabled_false
    run mlat_config_state active
    [ "$output" = 'disabled mlat_enabled_false' ]
}

@test "mlat_config_state: active + state=disabled,reason=latitude_zero" {
    setup_mlat_state_test_env
    write_mlat_state disabled latitude_zero
    run mlat_config_state active
    [ "$output" = 'disabled latitude_zero' ]
}

@test "mlat_config_state: active + state=misconfigured,reason=mlat_user_empty" {
    setup_mlat_state_test_env
    write_mlat_state misconfigured mlat_user_empty
    run mlat_config_state active
    [ "$output" = 'misconfigured mlat_user_empty' ]
}

@test "mlat_config_state: activating + state=disabled (continuous across restart cycle)" {
    setup_mlat_state_test_env
    write_mlat_state disabled mlat_enabled_false
    run mlat_config_state activating
    [ "$output" = 'disabled mlat_enabled_false' ]
}

@test "mlat_config_state: active + no state file -> 'unknown -'" {
    setup_mlat_state_test_env
    # No write_mlat_state — file is absent.
    run mlat_config_state active
    [ "$output" = 'unknown -' ]
}

@test "mlat_config_state: failed + ExecMainStatus=64 + state file present -> misconfigured reason" {
    setup_mlat_state_test_env
    write_mlat_state misconfigured mlat_user_empty
    stub_systemctl failed 64
    run mlat_config_state failed
    [ "$output" = 'misconfigured mlat_user_empty' ]
}

@test "mlat_config_state: failed + ExecMainStatus=64 + no state file -> 'misconfigured unknown'" {
    setup_mlat_state_test_env
    stub_systemctl failed 64
    run mlat_config_state failed
    [ "$output" = 'misconfigured unknown' ]
}

@test "mlat_config_state: failed + ExecMainStatus=1 -> 'failed exit_1'" {
    setup_mlat_state_test_env
    stub_systemctl failed 1
    run mlat_config_state failed
    [ "$output" = 'failed exit_1' ]
}

@test "mlat_config_state: inactive -> 'inactive -'" {
    setup_mlat_state_test_env
    run mlat_config_state inactive
    [ "$output" = 'inactive -' ]
}

@test "mlat_config_state: empty active_state -> 'inactive -'" {
    setup_mlat_state_test_env
    run mlat_config_state ''
    [ "$output" = 'inactive -' ]
}

# ---- read_aircraft_snapshot -----------------------------------------------

@test "read_aircraft_snapshot: missing file -> ||" {
    [ "$(read_aircraft_snapshot)" = "||" ]
}

@test "read_aircraft_snapshot: well-formed JSON -> count|messages|now" {
    cat > "$PATHS_AIRCRAFT_JSON" <<'EOF'
{
  "now": 1717000000,
  "messages": 1234,
  "aircraft": [
    {"hex":"a"},
    {"hex":"b"},
    {"hex":"c"}
  ]
}
EOF
    [ "$(read_aircraft_snapshot)" = "3|1234|1717000000" ]
}

@test "read_aircraft_snapshot: malformed JSON -> ||" {
    printf 'this is not json' > "$PATHS_AIRCRAFT_JSON"
    [ "$(read_aircraft_snapshot)" = "||" ]
}

@test "snapshot: messages='bad' (string) does not crash renderer" {
    # Defensive: even though readsb's contract is integers, a corrupted
    # aircraft.json must not bring the dashboard down.
    cat > "$PATHS_AIRCRAFT_JSON" <<'EOF'
{ "now": 100, "messages": "bad", "aircraft": [{"hex":"a"}] }
EOF
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
}

@test "snapshot: messages=1.5 (float) does not crash renderer" {
    cat > "$PATHS_AIRCRAFT_JSON" <<'EOF'
{ "now": 100, "messages": 1.5, "aircraft": [{"hex":"a"}] }
EOF
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
}

# ---- read_local_urls -------------------------------------------------------

@test "read_local_urls: returns at least one usable string" {
    out="$(read_local_urls)"
    [ -n "$out" ]
    # Either an http URL or the not-connected sentinel.
    [[ "$out" =~ ^http://|^\(not\ connected\)$ ]]
}

# Helper: shim PATH with mock `hostname` and `ip`. The fixture exercises the
# function's own logic (raspberrypi suppression, IP/.local join) rather than
# whatever the test host happens to expose.
_local_urls_shim() {
    local shim="$TMP/shim-net"
    mkdir -p "$shim"
    cat > "$shim/hostname" <<'HOSTNAME_EOF'
#!/bin/bash
printf '%s\n' "${MOCK_HOSTNAME:-localhost}"
HOSTNAME_EOF
    chmod +x "$shim/hostname"
    cat > "$shim/ip" <<'IP_EOF'
#!/bin/bash
# Mock the format `ip -4 -o addr show scope global` produces.
if [[ -n "${MOCK_IP:-}" ]]; then
    printf '2: eth0    inet %s/24 brd 192.168.1.255 scope global eth0\n' "$MOCK_IP"
fi
IP_EOF
    chmod +x "$shim/ip"
    printf '%s' "$shim"
}

@test "read_local_urls: hostname=raspberrypi suppresses .local, returns IP only" {
    shim="$(_local_urls_shim)"
    PATH="$shim:$PATH"
    out="$(MOCK_HOSTNAME=raspberrypi MOCK_IP=192.168.1.42 read_local_urls)"
    [ "$out" = "http://192.168.1.42" ]
}

@test "read_local_urls: non-default hostname joins IP and .local" {
    shim="$(_local_urls_shim)"
    PATH="$shim:$PATH"
    out="$(MOCK_HOSTNAME=feeder1 MOCK_IP=192.168.1.42 read_local_urls)"
    [ "$out" = "http://192.168.1.42  or  http://feeder1.local" ]
}

@test "read_local_urls: no IP, default hostname yields '(not connected)'" {
    shim="$(_local_urls_shim)"
    PATH="$shim:$PATH"
    out="$(MOCK_HOSTNAME=raspberrypi read_local_urls)"
    [ "$out" = "(not connected)" ]
}

# ---- read_build_short_sha --------------------------------------------------

@test "read_build_short_sha: valid 40-hex SHA returns 7-char prefix" {
    cat > "$PATHS_MANIFEST" <<'EOF'
{ "components": { "airplanes_feed": "abcdef1234567890123456789012345678901234" } }
EOF
    [ "$(read_build_short_sha)" = "abcdef1" ]
}

@test "read_build_short_sha: empty .components.airplanes_feed returns empty" {
    cat > "$PATHS_MANIFEST" <<'EOF'
{ "components": {} }
EOF
    [ -z "$(read_build_short_sha)" ]
}

@test "read_build_short_sha: malformed JSON returns empty" {
    printf 'not json\n' > "$PATHS_MANIFEST"
    [ -z "$(read_build_short_sha)" ]
}

@test "read_build_short_sha: SHA with wrong length returns empty" {
    cat > "$PATHS_MANIFEST" <<'EOF'
{ "components": { "airplanes_feed": "abc1234" } }
EOF
    [ -z "$(read_build_short_sha)" ]
}

# ---- unit_state ------------------------------------------------------------
#
# Regression test for the rc-capture bug: bash sets $? to 0 after `if cmd;
# then …; fi` whose body did not run, so `active_rc=$?` was always 0 and the
# `timeout` branch was unreachable. The is-enabled call had a parallel issue
# — its rc was discarded by `|| true` in command-substitution, so a stalled
# dbus burned the timeout budget twice per unit. The fix captures both rcs
# explicitly and short-circuits on 124.

# Helper: shim PATH with mock `systemctl` and `timeout`. The mocks are env-
# driven so each test can dial a single state without mutating the others.
# The timeout shim also logs each probed verb to PROBE_LOG when set, so a
# test can assert that is-active is skipped after an is-enabled timeout
# (without a guard, a regression could re-introduce the doubled stall).
_unit_state_shim() {
    local shim="$TMP/shim-systemd"
    mkdir -p "$shim"
    cat > "$shim/timeout" <<'TIMEOUT_EOF'
#!/bin/bash
shift  # drop the duration argument
verb="$2"  # $1=systemctl, $2=verb
if [[ -n "${PROBE_LOG:-}" ]]; then
    printf '%s\n' "$verb" >> "$PROBE_LOG"
fi
if [[ "$verb" == "is-enabled" && -n "${MOCK_TIMEOUT_IS_ENABLED:-}" ]]; then
    exit 124
fi
if [[ "$verb" == "is-active" && -n "${MOCK_TIMEOUT_IS_ACTIVE:-}" ]]; then
    exit 124
fi
exec "$@"
TIMEOUT_EOF
    chmod +x "$shim/timeout"
    cat > "$shim/systemctl" <<'SYSTEMCTL_EOF'
#!/bin/bash
verb="$1"
case "$verb" in
    is-enabled)
        # Real systemctl prints the state on stdout AND signals via rc:
        # rc 0 for enabled/static, nonzero for disabled/masked. Mirror that
        # so a future regression that consults the rc is exercised.
        printf '%s\n' "${MOCK_IS_ENABLED:-static}"
        exit "${MOCK_IS_ENABLED_RC:-0}"
        ;;
    is-active)
        exit "${MOCK_IS_ACTIVE_RC:-0}"
        ;;
esac
exit 0
SYSTEMCTL_EOF
    chmod +x "$shim/systemctl"
    printf '%s' "$shim"
}

@test "unit_state: masked unit returns 'masked'" {
    shim="$(_unit_state_shim)"
    PATH="$shim:$PATH"
    out="$(MOCK_IS_ENABLED=masked MOCK_IS_ENABLED_RC=1 unit_state airplanes-feed.service)"
    [ "$out" = "masked" ]
}

@test "unit_state: enabled+active returns 'ok'" {
    shim="$(_unit_state_shim)"
    PATH="$shim:$PATH"
    out="$(MOCK_IS_ENABLED=enabled MOCK_IS_ACTIVE_RC=0 unit_state airplanes-feed.service)"
    [ "$out" = "ok" ]
}

@test "unit_state: enabled+inactive returns 'fail'" {
    shim="$(_unit_state_shim)"
    PATH="$shim:$PATH"
    out="$(MOCK_IS_ENABLED=enabled MOCK_IS_ACTIVE_RC=3 unit_state airplanes-feed.service)"
    [ "$out" = "fail" ]
}

@test "unit_state: disabled+inactive returns 'disabled'" {
    shim="$(_unit_state_shim)"
    PATH="$shim:$PATH"
    # Real systemctl exits 1 for a disabled unit while still printing 'disabled'.
    out="$(MOCK_IS_ENABLED=disabled MOCK_IS_ENABLED_RC=1 MOCK_IS_ACTIVE_RC=3 unit_state airplanes-feed.service)"
    [ "$out" = "disabled" ]
}

@test "unit_state: is-enabled timeout returns 'timeout' and skips is-active" {
    shim="$(_unit_state_shim)"
    PATH="$shim:$PATH"
    log="$TMP/probes-enabled-timeout"
    : > "$log"
    out="$(MOCK_TIMEOUT_IS_ENABLED=1 PROBE_LOG=$log unit_state airplanes-feed.service)"
    [ "$out" = "timeout" ]
    # Critical: is-active must NOT be probed after is-enabled timed out, or
    # the dbus-stall budget doubles per unit and the SSH-login MOTD can take
    # ~20s with five units.
    [ "$(cat "$log")" = "is-enabled" ]
}

@test "unit_state: is-active timeout returns 'timeout' (after is-enabled succeeds)" {
    shim="$(_unit_state_shim)"
    PATH="$shim:$PATH"
    log="$TMP/probes-active-timeout"
    : > "$log"
    out="$(MOCK_IS_ENABLED=enabled MOCK_TIMEOUT_IS_ACTIVE=1 PROBE_LOG=$log unit_state airplanes-feed.service)"
    [ "$out" = "timeout" ]
    # Both probes ran; is-active timed out as expected.
    [ "$(sed -n '1p' "$log")" = "is-enabled" ]
    [ "$(sed -n '2p' "$log")" = "is-active" ]
}

# ---- snapshot end-to-end (full render with all sources missing) ------------

@test "snapshot: exits 0 with all sources missing" {
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
}

@test "snapshot: contains all section headers" {
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    [[ "$output" == *Access* ]]
    [[ "$output" == *"Feeder ID"* ]]
    [[ "$output" == *Claim* ]]
    [[ "$output" == *Services* ]]
    [[ "$output" == *Feed* ]]
    [[ "$output" == *Build* ]]
    [[ "$output" == *System* ]]
}

@test "snapshot: shows '(not yet generated)' when feeder-id missing" {
    run bash "$SCRIPT" --snapshot
    [[ "$output" == *"(not yet generated)"* ]]
}

@test "snapshot: shows 'unclaimed' when no claim files" {
    run bash "$SCRIPT" --snapshot
    [[ "$output" == *unclaimed* ]]
}

@test "snapshot: never leaks the canonical 16 uppercase-alnum secret form" {
    # Real claim secrets are 16 uppercase A-Z0-9 (per feed/scripts/apl-feed
    # validate_secret). Fixture mirrors that shape; if the renderer ever
    # cracks open the secret file, this match will fire.
    printf 'ABCDEFGHIJKLMNOP\n' > "$PATHS_CLAIM_SECRET"
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    if echo "$output" | grep -E -q '[A-Z0-9]{16}'; then
        false
    fi
}

@test "snapshot: never leaks the displayed XXXX-XXXX-XXXX-XXXX secret form" {
    # apl-feed claim show prints the secret in 4-grouped form. Same guard
    # against the renderer ever touching display formatting of a secret.
    printf 'ABCDEFGHIJKLMNOP\n' > "$PATHS_CLAIM_SECRET"
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    if echo "$output" | grep -E -q '([A-Z0-9]{4}-){3}[A-Z0-9]{4}'; then
        false
    fi
}

@test "snapshot: never leaks 32+ hex-char run" {
    printf '0123456789abcdef0123456789abcdef\n' > "$PATHS_CLAIM_SECRET"
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    if echo "$output" | grep -E -q '[0-9a-f]{32,}'; then
        false
    fi
}

@test "snapshot: never leaks the literal 'feeder-claim-secret' string" {
    : > "$PATHS_CLAIM_SECRET"
    run bash "$SCRIPT" --snapshot
    if echo "$output" | grep -q 'feeder-claim-secret'; then
        false
    fi
}

@test "snapshot: build channel + sha read from manifest" {
    printf 'dev\n' > "$PATHS_RELEASE_CHANNEL"
    cat > "$PATHS_MANIFEST" <<'EOF'
{
  "schema_version": 1,
  "channel": "dev",
  "components": {
    "airplanes_feed": "abcdef1234567890123456789012345678901234"
  }
}
EOF
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    [[ "$output" =~ channel=dev ]]
    [[ "$output" =~ sha=abcdef1 ]]
}

@test "snapshot: omits msgs/s field (rate requires two samples)" {
    cat > "$PATHS_AIRCRAFT_JSON" <<'EOF'
{ "now": 100, "messages": 5, "aircraft": [{"hex":"a"}] }
EOF
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    [[ "$output" == *"aircraft: 1"* ]]
    if echo "$output" | grep -q 'msgs/s'; then
        false
    fi
}

@test "render_once live: counter reset prints '-', then re-baselines next frame" {
    # Simulate a readsb restart: previous frame saw 1000 messages at t=90,
    # the next frame sees 500 at t=100. Frame 1 must print 'msgs/s: -' (no
    # bogus negative rate) AND update PREV_MSGS/PREV_TS so the next frame
    # computes a normal positive rate. Redirect to a file rather than
    # capturing via $(...) so the script-level globals update in this
    # shell — a subshell would lose the re-baseline and a regression that
    # never updated PREV_* after a counter reset would still pass.
    cat > "$PATHS_AIRCRAFT_JSON" <<'EOF'
{ "now": 100, "messages": 500, "aircraft": [{"hex":"a"}] }
EOF
    PREV_MSGS=1000
    PREV_TS=90
    frame1="$TMP/frame1"
    render_once live > "$frame1"
    grep -q 'msgs/s: -' "$frame1"
    [ "$PREV_MSGS" = "500" ]
    [ "$PREV_TS" = "100" ]

    # Frame 2: 10 new messages over 10 seconds -> 1.0 msgs/s.
    cat > "$PATHS_AIRCRAFT_JSON" <<'EOF'
{ "now": 110, "messages": 510, "aircraft": [{"hex":"a"}] }
EOF
    frame2="$TMP/frame2"
    render_once live > "$frame2"
    grep -qE 'msgs/s: 1\.0' "$frame2"
}

# ---- live mode framing -----------------------------------------------------
#
# Regression guard for the "duplicate lines" bug: --live must emit a full
# clear (\e[H\e[J) before every frame. Without it, lines that get shorter
# between frames leave stale trailing characters from the previous render.

@test "live: first frame begins with full clear (\\e[H\\e[J)" {
    OUT="$TMP/live-out"
    # SIGTERM the infinite loop after 1s — easily enough for the first frame
    # (single render_once + entering sleep). `|| true` because timeout exits
    # 124/143 on signal.
    timeout 1 bash "$SCRIPT" --live > "$OUT" 2>&1 || true
    expected=$'\033[H\033[J'
    actual="$(head -c 6 "$OUT" 2>/dev/null)"
    [ "$actual" = "$expected" ]
}

# ---- MOTD wrapper env-scrub guard ------------------------------------------
#
# pam_motd inherits the user's session env. Without scrubbing, a logged-in
# user could set PATHS_LOGO=/etc/airplanes/feeder-claim-secret in their SSH
# session and the renderer would `cat` that file as root via the MOTD path.
# The wrapper unsets PATHS_* before exec; verify by setting a hostile
# PATHS_LOGO that points at a fixture and asserting nothing from that file
# appears in the output.

@test "MOTD wrapper: PATHS_* env overrides are stripped before exec" {
    MOTD_WRAPPER="$BATS_TEST_DIRNAME/../stage-airplanes/06b-console-dashboard/files/etc/update-motd.d/10-airplanes-status"
    HOSTILE="$TMP/hostile-logo"
    printf 'HOSTILE-PAYLOAD-MUST-NOT-APPEAR-IN-MOTD-OUTPUT\n' > "$HOSTILE"

    # Wrapper hardcodes the renderer path at /usr/local/lib/airplanes; we
    # don't have that on the test host, so we shim it via a temp PATH.
    TMP_LIB="$TMP/usrlocallibairplanes"
    mkdir -p "$TMP_LIB"
    cp "$SCRIPT" "$TMP_LIB/render-status"
    chmod +x "$TMP_LIB/render-status"
    SHIM_DIR="$TMP/shim"
    mkdir -p "$SHIM_DIR"
    cat > "$SHIM_DIR/wrapper" <<EOF
#!/bin/bash
unset "\${!PATHS_@}"
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
exec $TMP_LIB/render-status --snapshot
EOF
    chmod +x "$SHIM_DIR/wrapper"

    run env PATHS_LOGO="$HOSTILE" TERM=dumb "$SHIM_DIR/wrapper"
    [ "$status" -eq 0 ]
    if echo "$output" | grep -q HOSTILE-PAYLOAD; then
        false
    fi
}

@test "MOTD wrapper: env-scrub directives present in source" {
    MOTD_WRAPPER="$BATS_TEST_DIRNAME/../stage-airplanes/06b-console-dashboard/files/etc/update-motd.d/10-airplanes-status"
    # shellcheck disable=SC2016  # literal grep target, no expansion intended
    grep -q '^unset "${!PATHS_@}"' "$MOTD_WRAPPER"
    grep -q '^PATH=' "$MOTD_WRAPPER"
    grep -q '^export PATH' "$MOTD_WRAPPER"
}

# ---- Layout dispatch & artwork loader -------------------------------------
#
# The renderer picks layouts by mode + term_cols(). bats `run` doesn't
# allocate a TTY for stdout, so term_cols() falls back to 80. That means
# --snapshot/--once exercise side-by-side, --live exercises the narrow
# fallback (80 < BANNER_WIDTH=135 → vertical_full_with_logo). Each path
# is tested below.

@test "load_artwork: rejects file with wrong line width" {
    local bad="$TMP/wrong-width-logo"
    # 39 cols instead of LOGO_WIDTH=40.
    printf '%s\n' "$(printf '%39s' '')" > "$bad"
    declare -a out=()
    run ! load_artwork "$bad" 40 out
}

@test "load_artwork: rejects CRLF" {
    local bad="$TMP/crlf-logo"
    # 40 cols, but with a stray \r on line 1.
    printf '%39s\r\n' '' > "$bad"
    declare -a out=()
    run ! load_artwork "$bad" 40 out
}

@test "load_artwork: counts UTF-8 block chars as 1 cell each" {
    local good="$TMP/utf8-logo"
    # Five Unicode "█" characters padded with 35 spaces = 40 cells.
    printf '%s%s\n' '█████' "$(printf '%35s' '')" > "$good"
    declare -a out=()
    load_artwork "$good" 40 out
    [ "${#out[@]}" = "1" ]
}

@test "snapshot: side-by-side puts the logo column to the left of status" {
    # Side-by-side prints `${logo[i]}  ${status[i]}` per row. The shipped
    # 40-col logo contains block characters; "Feeder ID" is one of the
    # early status rows. Verify the line containing it has a non-empty
    # prefix before the status text — i.e. the logo column is present.
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    line="$(printf '%s' "$output" | grep -m1 'Feeder ID' || true)"
    [ -n "$line" ]
    prefix="${line%%Feeder ID*}"
    # Vertical layout would place "Feeder ID" at byte 0 → empty prefix.
    [ -n "$prefix" ]
    # And the prefix must contain a non-whitespace character (the logo).
    [[ "$prefix" =~ [^[:space:]] ]]
}

@test "snapshot: every output line is <= 80 display cells" {
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    width="$(printf '%s' "$output" | strip_ansi | max_display_width)"
    (( width <= 80 ))
}

@test "live: vertical fallback fires when cols < 135 (bats default)" {
    # Under bats `run`, term_cols=80 (no TTY), so --live takes the
    # vertical_full_with_logo branch: small logo (40 cols) followed by the
    # full status block. No 135-col banner row should appear.
    OUT="$TMP/live-out"
    timeout 1 bash "$SCRIPT" --live > "$OUT" 2>&1 || true
    width="$(strip_ansi < "$OUT" | max_display_width)"
    # Logo lines are 40 cells; status lines at most ~80. Any line wider
    # than 80 means the 135-col banner leaked into a narrow terminal.
    (( width <= 80 ))
    # And the small logo must have rendered at least once.
    grep -q 'Access' "$OUT"
}

@test "render_banner_stack: emits 135-col banner lines + status content" {
    # Direct unit-test the banner-stack layout. Confirms PATHS_BANNER is
    # the source artwork and that the rendered banner is BANNER_WIDTH
    # cells wide. (Dispatch by mode + term_cols is straightforward case
    # logic; no separate test.)
    declare -a STATUS_LINES=("status-marker")
    out="$(render_banner_stack)"
    width="$(printf '%s' "$out" | strip_ansi | max_display_width)"
    [ "$width" = "135" ]
    [[ "$out" == *status-marker* ]]
}

@test "render_banner_stack: missing banner falls back to small logo" {
    PATHS_BANNER="$TMP/nx-banner"
    declare -a STATUS_LINES=("status-marker")
    out="$(render_banner_stack)"
    width="$(printf '%s' "$out" | strip_ansi | max_display_width)"
    # Logo is LOGO_WIDTH=40 cells wide.
    [ "$width" = "40" ]
    [[ "$out" == *status-marker* ]]
}

@test "snapshot with missing logo: degrades to status-only without crashing" {
    PATHS_LOGO="$TMP/nx-missing-logo"
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    # All section labels must still appear even with no artwork.
    [[ "$output" == *Access* ]]
    [[ "$output" == *"Feeder ID"* ]]
    [[ "$output" == *Services* ]]
    [[ "$output" == *Build* ]]
}

@test "live with missing banner: dispatch keeps narrow vertical layout" {
    # In bats `run` term_cols=80, so the dispatcher takes
    # render_vertical_full_with_logo regardless of banner presence. The
    # banner-missing path is exercised directly above; here we just
    # confirm --live with a missing banner.txt still produces a clean
    # frame (no crash, no stderr leak).
    PATHS_BANNER="$TMP/nx-missing-banner"
    OUT="$TMP/live-out"
    timeout 1 bash "$SCRIPT" --live > "$OUT" 2>&1 || true
    grep -q 'Access' "$OUT"
}

@test "term_cols: returns 80 when stdout is not a TTY" {
    # Sourcing the script runs term_cols here; bats has no TTY on stdout.
    [ "$(term_cols)" = "80" ]
}
