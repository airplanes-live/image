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
    export PATHS_STATE_FILE_978="$TMP/nx-978-state"
    export PATHS_STATE_READER_LIB="$TMP/nx-state-reader-lib"
    export PATHS_SYSFS_NET="$TMP/sysfs-net"
    export TERM=dumb  # disable color so assertions match plain text

    # Default `nmcli` stub: returns nothing for any call, so existing
    # snapshot tests don't pick up the host's real network state. The
    # network-section tests below overwrite the fixture files to drive
    # specific scenarios.
    install_default_nmcli_stub

    # shellcheck source=/dev/null
    source "$SCRIPT"
}

# Install a `nmcli` shim that dispatches on the argument tail:
#   - "-t -f DEVICE,TYPE,STATE dev status"           → cat $TMP/nmcli-dev-status
#   - "--rescan no -t -f IN-USE,SIGNAL,SSID dev wifi list ifname <iface>"
#                                                     → cat $TMP/nmcli-dev-wifi-<iface>
# Missing fixture files yield empty output (the no-op default). Tests
# write to these fixtures before invoking the renderer.
install_default_nmcli_stub() {
    local shim="$TMP/shim-nmcli"
    mkdir -p "$shim"
    cat > "$shim/nmcli" <<EOF
#!/bin/bash
case "\$*" in
    "-t -f DEVICE,TYPE,STATE dev status")
        [[ -f "$TMP/nmcli-dev-status" ]] && cat "$TMP/nmcli-dev-status"
        exit 0
        ;;
    "--rescan no -t -f IN-USE,SIGNAL,SSID dev wifi list ifname "*)
        iface="\${@: -1}"
        f="$TMP/nmcli-dev-wifi-\$iface"
        [[ -f "\$f" ]] && cat "\$f"
        exit 0
        ;;
esac
exit 0
EOF
    chmod +x "$shim/nmcli"
    PATH="$shim:$PATH"
}

# Write a /sys/class/net/<iface>/speed fixture (PATHS_SYSFS_NET-rooted).
write_eth_speed() {
    local iface="$1" mbps="$2"
    mkdir -p "$PATHS_SYSFS_NET/$iface"
    printf '%s\n' "$mbps" > "$PATHS_SYSFS_NET/$iface/speed"
}

teardown() { rm -rf "$TMP"; }

# Strip ANSI escapes so width / substring assertions can match what the
# user actually sees. Covers SGR (color, e.g. \e[31m), CSI cursor/erase
# (\e[H, \e[J, \e[K), and private-mode CSI (\e[?25l, \e[?25h) — the live
# loop emits all of these. None take display columns.
strip_ansi() {
    sed -E 's/'$'\x1b''\[[?0-9;]*[a-zA-Z]//g'
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

# ---- _prime_unit_props / _unit_prop (per-frame batched systemd cache) ----

# Build a `systemctl` stub whose `show -p ... -- u1 u2 …` output is fully
# controlled by a fixture written to $TMP/sysctl-show.out. Tests overwrite
# the fixture before invoking _prime_unit_props.
_systemctl_show_shim() {
    local shim="$TMP/shim-systemctl-show"
    mkdir -p "$shim"
    cat > "$shim/systemctl" <<EOF
#!/bin/bash
# We only care about \`show\` here; pass everything else through to a noop.
if [[ "\$1" == "show" ]]; then
    if [[ -n "\${PROBE_LOG:-}" ]]; then
        printf 'show\n' >> "\$PROBE_LOG"
    fi
    [[ -f "$TMP/sysctl-show.out" ]] && cat "$TMP/sysctl-show.out"
    exit 0
fi
exit 0
EOF
    chmod +x "$shim/systemctl"
    cat > "$shim/timeout" <<'EOF'
#!/bin/bash
shift  # drop the duration arg
if [[ "$MOCK_TIMEOUT_RC" =~ ^[0-9]+$ ]]; then
    exit "$MOCK_TIMEOUT_RC"
fi
exec "$@"
EOF
    chmod +x "$shim/timeout"
    printf '%s' "$shim"
}

@test "_prime_unit_props: success populates SD_UNIT_PROPS keyed by Id" {
    shim="$(_systemctl_show_shim)"
    PATH="$shim:$PATH"
    cat > "$TMP/sysctl-show.out" <<'EOF'
Id=airplanes-feed.service
ActiveState=active
UnitFileState=enabled
ExecMainStatus=0

Id=airplanes-mlat.service
ActiveState=active
UnitFileState=enabled
ExecMainStatus=0

Id=readsb.service
ActiveState=active
UnitFileState=enabled
ExecMainStatus=0

Id=dump978-fa.service
ActiveState=inactive
UnitFileState=disabled
ExecMainStatus=0

Id=airplanes-978.service
ActiveState=inactive
UnitFileState=disabled
ExecMainStatus=0
EOF
    _prime_unit_props
    [ "$SD_UNIT_PROPS_PRIMED" = "1" ]
    [ "${SD_UNIT_PROPS[airplanes-feed.service.ActiveState]}" = "active" ]
    [ "${SD_UNIT_PROPS[airplanes-mlat.service.UnitFileState]}" = "enabled" ]
    [ "${SD_UNIT_PROPS[readsb.service.ActiveState]}" = "active" ]
    [ "${SD_UNIT_PROPS[dump978-fa.service.ActiveState]}" = "inactive" ]
    [ "${SD_UNIT_PROPS[airplanes-978.service.UnitFileState]}" = "disabled" ]
}

@test "_prime_unit_props: parses Id-keyed blocks regardless of order" {
    # systemctl normally emits blocks in argument order, but defending
    # against alias collapse / reorder means we must key by Id, not by
    # position in UNITS[@]. Stub returns blocks in reverse order; the
    # cache must still resolve correctly.
    shim="$(_systemctl_show_shim)"
    PATH="$shim:$PATH"
    cat > "$TMP/sysctl-show.out" <<'EOF'
Id=airplanes-978.service
ActiveState=failed
UnitFileState=enabled
ExecMainStatus=64

Id=dump978-fa.service
ActiveState=active
UnitFileState=enabled
ExecMainStatus=0

Id=readsb.service
ActiveState=reloading
UnitFileState=enabled
ExecMainStatus=0

Id=airplanes-mlat.service
ActiveState=inactive
UnitFileState=disabled
ExecMainStatus=0

Id=airplanes-feed.service
ActiveState=active
UnitFileState=enabled
ExecMainStatus=0
EOF
    _prime_unit_props
    [ "$SD_UNIT_PROPS_PRIMED" = "1" ]
    [ "${SD_UNIT_PROPS[airplanes-feed.service.ActiveState]}" = "active" ]
    [ "${SD_UNIT_PROPS[airplanes-978.service.ExecMainStatus]}" = "64" ]
    [ "${SD_UNIT_PROPS[readsb.service.ActiveState]}" = "reloading" ]
}

@test "_prime_unit_props: timeout (rc 124) sets PRIMED=2 and leaves cache empty" {
    shim="$(_systemctl_show_shim)"
    PATH="$shim:$PATH"
    MOCK_TIMEOUT_RC=124 _prime_unit_props
    [ "$SD_UNIT_PROPS_PRIMED" = "2" ]
    [ "${#SD_UNIT_PROPS[@]}" = "0" ]
}

@test "_prime_unit_props: non-zero rc (not 124) sets PRIMED=3" {
    shim="$(_systemctl_show_shim)"
    PATH="$shim:$PATH"
    MOCK_TIMEOUT_RC=1 _prime_unit_props
    [ "$SD_UNIT_PROPS_PRIMED" = "3" ]
    [ "${#SD_UNIT_PROPS[@]}" = "0" ]
}

@test "_prime_unit_props: no systemctl on PATH sets PRIMED=3" {
    # Empty PATH stub: systemctl absent. command -v must fail.
    old_path="$PATH"
    shim="$TMP/shim-empty"
    mkdir -p "$shim"
    PATH="$shim"
    _prime_unit_props
    primed="$SD_UNIT_PROPS_PRIMED"
    # Restore PATH BEFORE the assertion so bats's teardown (which calls
    # `rm`) can find its tools.
    PATH="$old_path"
    [ "$primed" = "3" ]
}

@test "_unit_prop: PRIMED=1 returns cached value, no fork" {
    shim="$(_systemctl_show_shim)"
    PATH="$shim:$PATH"
    PROBE_LOG="$TMP/probes-cache-hit"
    : > "$PROBE_LOG"
    SD_UNIT_PROPS=([airplanes-feed.service.ActiveState]="active")
    SD_UNIT_PROPS_PRIMED=1
    out="$(_unit_prop airplanes-feed.service ActiveState)"
    [ "$out" = "active" ]
    # Stub must not have been invoked.
    [ ! -s "$PROBE_LOG" ]
}

@test "_unit_prop: PRIMED=2 returns empty (no fork)" {
    shim="$(_systemctl_show_shim)"
    PATH="$shim:$PATH"
    PROBE_LOG="$TMP/probes-prime-timeout"
    : > "$PROBE_LOG"
    SD_UNIT_PROPS_PRIMED=2
    out="$(_unit_prop airplanes-feed.service ActiveState)"
    [ -z "$out" ]
    [ ! -s "$PROBE_LOG" ]
}

@test "_unit_prop: PRIMED=0 falls back to a live single-unit systemctl show" {
    # Test path: bats sourced the script and called _unit_prop directly,
    # without first running collect_status_data. We must still resolve
    # the property — by forking systemctl once for that unit.
    shim="$(_systemctl_show_shim)"
    PATH="$shim:$PATH"
    log="$TMP/probes-cache-miss"
    : > "$log"
    SD_UNIT_PROPS=()
    SD_UNIT_PROPS_PRIMED=0
    # Stub emits a value when invoked via `show --property=ActiveState --value <unit>`.
    cat > "$TMP/sysctl-show.out" <<'EOF'
active
EOF
    # Prefix-export PROBE_LOG so it propagates into the systemctl stub
    # (an external command in a `$( … )` subshell, which inherits only
    # exported env vars).
    out="$(PROBE_LOG="$log" _unit_prop airplanes-feed.service ActiveState)"
    [ "$out" = "active" ]
    # Stub must have been invoked exactly once for the fallback.
    [ "$(wc -l < "$log")" = "1" ]
}

@test "unit_state_with_reason: PRIMED=2 short-circuits to 'timeout -'" {
    shim="$(_unit_state_shim)"
    PATH="$shim:$PATH"
    PROBE_LOG="$TMP/probes-timeout-shortcircuit"
    : > "$PROBE_LOG"
    SD_UNIT_PROPS_PRIMED=2
    out="$(unit_state_with_reason airplanes-feed.service)"
    [ "$out" = "timeout -" ]
    # Critical: no per-unit fork happened (is-enabled / is-active not invoked).
    [ ! -s "$PROBE_LOG" ]
    SD_UNIT_PROPS_PRIMED=0
}

@test "unit_state: PRIMED=1 + ActiveState=active returns 'ok' without forking" {
    shim="$(_unit_state_shim)"
    PATH="$shim:$PATH"
    PROBE_LOG="$TMP/probes-cache-active"
    : > "$PROBE_LOG"
    SD_UNIT_PROPS=(
        [airplanes-feed.service.UnitFileState]="enabled"
        [airplanes-feed.service.ActiveState]="active"
    )
    SD_UNIT_PROPS_PRIMED=1
    out="$(unit_state airplanes-feed.service)"
    [ "$out" = "ok" ]
    [ ! -s "$PROBE_LOG" ]
    SD_UNIT_PROPS=()
    SD_UNIT_PROPS_PRIMED=0
}

@test "unit_state: PRIMED=1 + UnitFileState=masked returns 'masked' without forking" {
    shim="$(_unit_state_shim)"
    PATH="$shim:$PATH"
    PROBE_LOG="$TMP/probes-cache-masked"
    : > "$PROBE_LOG"
    SD_UNIT_PROPS=(
        [readsb.service.UnitFileState]="masked"
        [readsb.service.ActiveState]="inactive"
    )
    SD_UNIT_PROPS_PRIMED=1
    out="$(unit_state readsb.service)"
    [ "$out" = "masked" ]
    [ ! -s "$PROBE_LOG" ]
    SD_UNIT_PROPS=()
    SD_UNIT_PROPS_PRIMED=0
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
# Framing contract for --live:
#   * Hide the cursor on entry (\e[?25l) and restore it on exit (\e[?25h),
#     so in-flight per-line repaints don't show a stepping caret.
#   * The first painted byte after \e[?25l is \e[H (cursor home) — NOT
#     \e[H\e[J. A full pre-clear would blank the screen during data
#     gathering and cause the 1-2s flash the previous implementation had.
#   * Each rendered line is followed by \e[K (erase to end of line) so a
#     shorter new line clears trailing chars from the previous frame in
#     place — no full-screen clear needed.

@test "live: first frame opens with cursor hide + home, never full pre-clear" {
    OUT="$TMP/live-out"
    # SIGTERM the infinite loop after 2s — long enough to absorb the
    # worst-case `_prime_unit_props` budget (one `timeout 2 systemctl
    # show` per frame) on a slow CI runner, before the first paint
    # lands. `|| true` because timeout returns 124/143 on signal.
    timeout 2 bash "$SCRIPT" --live > "$OUT" 2>&1 || true
    # Cursor hide is the very first byte stream the dispatcher emits,
    # before any rendered content.
    expected_hide=$'\033[?25l'
    head_bytes="$(head -c "${#expected_hide}" "$OUT" 2>/dev/null)"
    [ "$head_bytes" = "$expected_hide" ]
    # The output must NOT contain the old full-screen pre-clear sequence.
    ! grep -q $'\033\[H\033\[J' "$OUT"
    # Each rendered line is followed by \e[K (erase to end of line).
    grep -q $'\033\[K' "$OUT"
}

@test "live: cursor is restored after the loop exits" {
    OUT="$TMP/live-out"
    timeout 2 bash "$SCRIPT" --live > "$OUT" 2>&1 || true
    # Cursor show (\e[?25h) is emitted by the EXIT/INT/TERM/HUP trap.
    grep -q $'\033\[?25h' "$OUT"
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
    timeout 2 bash "$SCRIPT" --live > "$OUT" 2>&1 || true
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
    timeout 2 bash "$SCRIPT" --live > "$OUT" 2>&1 || true
    grep -q 'Access' "$OUT"
}

@test "term_cols: returns 80 when stdout is not a TTY" {
    # Sourcing the script runs term_cols here; bats has no TTY on stdout.
    [ "$(term_cols)" = "80" ]
}

# ---- _978_config_state (PR 4) — same shape as mlat_config_state -----------

write_978_state() {
    # write_978_state <decision> <reason>
    local decision="$1" reason="$2"
    mkdir -p "$(dirname "$PATHS_STATE_FILE_978")"
    {
        printf 'schema_version=1\n'
        printf 'service=airplanes-978\n'
        printf 'state=%s\n' "$decision"
        printf 'reason=%s\n' "$reason"
    } > "$PATHS_STATE_FILE_978"
}

setup_978_state_test_env() {
    install_state_reader_stub
    PATHS_STATE_FILE_978="$TMP/run/airplanes-978/state"
}

# Stub systemctl returning chosen ActiveState/ExecMainStatus for the
# 978-specific unit (mirrors stub_systemctl but parameterizes on unit
# so we can simulate dump978-fa.service exit-64 separately).
stub_systemctl_978() {
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

@test "_978_config_state: active + state=enabled,reason=ok" {
    setup_978_state_test_env
    write_978_state enabled ok
    run _978_config_state active
    [ "$status" -eq 0 ]
    [ "$output" = 'enabled ok' ]
}

@test "_978_config_state: active + state=disabled,reason=uat_disabled" {
    setup_978_state_test_env
    write_978_state disabled uat_disabled
    run _978_config_state active
    [ "$output" = 'disabled uat_disabled' ]
}

@test "_978_config_state: active + state=misconfigured,reason=uat_input_invalid" {
    setup_978_state_test_env
    write_978_state misconfigured uat_input_invalid
    run _978_config_state active
    [ "$output" = 'misconfigured uat_input_invalid' ]
}

@test "_978_config_state: failed + ExecMainStatus=64 + state file present → propagates state+reason" {
    setup_978_state_test_env
    write_978_state disabled uat_disabled
    stub_systemctl_978 failed 64
    run _978_config_state failed airplanes-978.service
    [ "$output" = 'disabled uat_disabled' ]
}

@test "_978_config_state: failed + ExecMainStatus=64 + state file absent → 'misconfigured unknown'" {
    setup_978_state_test_env
    # Do NOT write state file — race window where dump978-fa exited 64
    # before airplanes-978 wrote state.
    stub_systemctl_978 failed 64
    run _978_config_state failed dump978-fa.service
    [ "$output" = 'misconfigured unknown' ]
}

@test "_978_config_state: failed + ExecMainStatus=1 → 'failed exit_1'" {
    setup_978_state_test_env
    write_978_state enabled ok
    stub_systemctl_978 failed 1
    run _978_config_state failed airplanes-978.service
    [ "$output" = 'failed exit_1' ]
}

@test "_978_config_state: inactive → 'inactive -'" {
    setup_978_state_test_env
    run _978_config_state inactive
    [ "$output" = 'inactive -' ]
}

@test "_978_config_state: active + no state file → 'unknown -'" {
    setup_978_state_test_env
    # No write_978_state — file is absent.
    run _978_config_state active
    [ "$output" = 'unknown -' ]
}

@test "unit_state_with_reason: dump978-fa active + state=disabled → 'disabled-by-config uat_disabled'" {
    setup_978_state_test_env
    write_978_state disabled uat_disabled
    stub_systemctl_978 active 0
    run unit_state_with_reason dump978-fa.service
    [ "$output" = 'disabled-by-config uat_disabled' ]
}

@test "unit_state_with_reason: airplanes-978 failed + exit-64 + state=misconfigured → 'misconfigured uat_input_invalid'" {
    setup_978_state_test_env
    write_978_state misconfigured uat_input_invalid
    stub_systemctl_978 failed 64
    run unit_state_with_reason airplanes-978.service
    [ "$output" = 'misconfigured uat_input_invalid' ]
}

# ---- Network section: _fmt_eth_speed ---------------------------------------

@test "_fmt_eth_speed: empty input → 'up'" {
    [ "$(_fmt_eth_speed '')" = "up" ]
}

@test "_fmt_eth_speed: -1 (no link) → 'up'" {
    [ "$(_fmt_eth_speed -1)" = "up" ]
}

@test "_fmt_eth_speed: 0 → 'up'" {
    [ "$(_fmt_eth_speed 0)" = "up" ]
}

@test "_fmt_eth_speed: non-numeric → 'up'" {
    [ "$(_fmt_eth_speed garbage)" = "up" ]
}

@test "_fmt_eth_speed: 100 → '100 Mbps'" {
    [ "$(_fmt_eth_speed 100)" = "100 Mbps" ]
}

@test "_fmt_eth_speed: 1000 → '1 Gbps'" {
    [ "$(_fmt_eth_speed 1000)" = "1 Gbps" ]
}

@test "_fmt_eth_speed: 2500 (2.5GbE) stays Mbps" {
    [ "$(_fmt_eth_speed 2500)" = "2500 Mbps" ]
}

@test "_fmt_eth_speed: 10000 → '10 Gbps'" {
    [ "$(_fmt_eth_speed 10000)" = "10 Gbps" ]
}

# ---- Network section: _unescape_nmcli_field --------------------------------

@test "_unescape_nmcli_field: bare ASCII passes through" {
    [ "$(_unescape_nmcli_field 'PlainSSID')" = "PlainSSID" ]
}

@test "_unescape_nmcli_field: escaped colon → literal colon" {
    [ "$(_unescape_nmcli_field 'Home\:Net')" = "Home:Net" ]
}

@test "_unescape_nmcli_field: escaped backslash → literal backslash" {
    [ "$(_unescape_nmcli_field 'Back\\slash')" = 'Back\slash' ]
}

@test "_unescape_nmcli_field: original '\\:' (encoded as '\\\\\\:') round-trips" {
    # nmcli encodes a literal '\:' as '\\\:': '\' → '\\' first, then ':' → '\:'.
    # Two-pass swap via placeholder should yield '\:', not ':'.
    [ "$(_unescape_nmcli_field 'A\\\:B')" = 'A\:B' ]
}

# ---- Network section: _read_eth_speed_mbps ---------------------------------

@test "_read_eth_speed_mbps: missing file → empty" {
    [ -z "$(_read_eth_speed_mbps eth-missing)" ]
}

@test "_read_eth_speed_mbps: returns raw integer from sysfs file" {
    write_eth_speed end0 1000
    [ "$(_read_eth_speed_mbps end0)" = "1000" ]
}

# ---- Network section: _eth_line_for ---------------------------------------

@test "_eth_line_for: connected + 1000 → 'end0: 1 Gbps'" {
    write_eth_speed end0 1000
    [ "$(_eth_line_for end0 connected)" = "end0: 1 Gbps" ]
}

@test "_eth_line_for: connected + missing speed → 'end0: up'" {
    [ "$(_eth_line_for end0 connected)" = "end0: up" ]
}

@test "_eth_line_for: connected + -1 (no carrier) → 'end0: up'" {
    write_eth_speed end0 -1
    [ "$(_eth_line_for end0 connected)" = "end0: up" ]
}

@test "_eth_line_for: config state → 'end0: connecting…'" {
    [ "$(_eth_line_for end0 config)" = "end0: connecting…" ]
}

@test "_eth_line_for: failed → 'end0: link failed'" {
    [ "$(_eth_line_for end0 failed)" = "end0: link failed" ]
}

@test "_eth_line_for: unmanaged → empty (not reportable)" {
    [ -z "$(_eth_line_for end0 unmanaged)" ]
}

@test "_eth_line_for: disconnected → empty (not reportable)" {
    [ -z "$(_eth_line_for end0 disconnected)" ]
}

# ---- Network section: _wifi_line_for --------------------------------------

@test "_wifi_line_for: connected + SSID + signal → 'wlan0: MyHome 78%'" {
    printf '*:78:MyHome\n' > "$TMP/nmcli-dev-wifi-wlan0"
    printf ':45:Neighbor\n' >> "$TMP/nmcli-dev-wifi-wlan0"
    [ "$(_wifi_line_for wlan0 connected)" = "wlan0: MyHome 78%" ]
}

@test "_wifi_line_for: connected + escaped colon in SSID unescapes" {
    printf '*:78:Home\\:Net\n' > "$TMP/nmcli-dev-wifi-wlan0"
    [ "$(_wifi_line_for wlan0 connected)" = "wlan0: Home:Net 78%" ]
}

@test "_wifi_line_for: connected + hidden SSID (empty) → 'wlan0: 78%'" {
    printf '*:78:\n' > "$TMP/nmcli-dev-wifi-wlan0"
    [ "$(_wifi_line_for wlan0 connected)" = "wlan0: 78%" ]
}

@test "_wifi_line_for: connected + no IN-USE row → 'wlan0: up'" {
    # Race: device shows connected in dev status, but the wifi list query
    # returns no row marked with '*' yet. Fall back to a bare "up" marker
    # rather than displaying nothing.
    printf ':45:Neighbor\n' > "$TMP/nmcli-dev-wifi-wlan0"
    [ "$(_wifi_line_for wlan0 connected)" = "wlan0: up" ]
}

@test "_wifi_line_for: connected + signal out of range → SSID only" {
    printf '*:999:MyHome\n' > "$TMP/nmcli-dev-wifi-wlan0"
    [ "$(_wifi_line_for wlan0 connected)" = "wlan0: MyHome" ]
}

@test "_wifi_line_for: connected + signal non-numeric → SSID only" {
    # Regex on IN-USE row requires numeric signal; non-matches fall through.
    printf '*:--:MyHome\n' > "$TMP/nmcli-dev-wifi-wlan0"
    # No match → no signal/ssid captured → falls back to "up"
    [ "$(_wifi_line_for wlan0 connected)" = "wlan0: up" ]
}

@test "_wifi_line_for: config state → 'wlan0: associating…'" {
    [ "$(_wifi_line_for wlan0 config)" = "wlan0: associating…" ]
}

@test "_wifi_line_for: ip-config state → 'wlan0: associating…'" {
    [ "$(_wifi_line_for wlan0 ip-config)" = "wlan0: associating…" ]
}

@test "_wifi_line_for: failed → diagnostic about WIFI_PASS" {
    [ "$(_wifi_line_for wlan0 failed)" = "wlan0: failed (WIFI_PASS?)" ]
}

@test "_wifi_line_for: disconnected → empty (not reportable)" {
    [ -z "$(_wifi_line_for wlan0 disconnected)" ]
}

# ---- Network section: read_network_lines (end-to-end of the helper) -------

@test "read_network_lines: nmcli returns nothing → no lines" {
    out="$(read_network_lines)"
    [ -z "$out" ]
}

@test "read_network_lines: eth connected → 'end0: 1 Gbps'" {
    printf 'end0:ethernet:connected\n' > "$TMP/nmcli-dev-status"
    write_eth_speed end0 1000
    out="$(read_network_lines)"
    [ "$out" = "end0: 1 Gbps" ]
}

@test "read_network_lines: wifi connected → 'wlan0: MyHome 78%'" {
    printf 'wlan0:wifi:connected\n' > "$TMP/nmcli-dev-status"
    printf '*:78:MyHome\n' > "$TMP/nmcli-dev-wifi-wlan0"
    out="$(read_network_lines)"
    [ "$out" = "wlan0: MyHome 78%" ]
}

@test "read_network_lines: eth + wifi both connected → eth first, wifi second" {
    cat > "$TMP/nmcli-dev-status" <<'EOF'
end0:ethernet:connected
wlan0:wifi:connected
lo:loopback:unmanaged
EOF
    write_eth_speed end0 1000
    printf '*:78:MyHome\n' > "$TMP/nmcli-dev-wifi-wlan0"
    mapfile -t out < <(read_network_lines)
    [ "${#out[@]}" = "2" ]
    [ "${out[0]}" = "end0: 1 Gbps" ]
    [ "${out[1]}" = "wlan0: MyHome 78%" ]
}

@test "read_network_lines: dev-status reported in wifi-first order → eth still rendered first" {
    cat > "$TMP/nmcli-dev-status" <<'EOF'
wlan0:wifi:connected
end0:ethernet:connected
EOF
    write_eth_speed end0 100
    printf '*:78:MyHome\n' > "$TMP/nmcli-dev-wifi-wlan0"
    mapfile -t out < <(read_network_lines)
    [ "${out[0]}" = "end0: 100 Mbps" ]
    [ "${out[1]}" = "wlan0: MyHome 78%" ]
}

@test "read_network_lines: only failed wifi (wrong PSK) surfaces the diagnostic" {
    printf 'wlan0:wifi:failed\n' > "$TMP/nmcli-dev-status"
    out="$(read_network_lines)"
    [ "$out" = "wlan0: failed (WIFI_PASS?)" ]
}

@test "read_network_lines: unmanaged loopback / disconnected ifaces are skipped" {
    cat > "$TMP/nmcli-dev-status" <<'EOF'
lo:loopback:unmanaged
wlan0:wifi:disconnected
end0:ethernet:unavailable
EOF
    out="$(read_network_lines)"
    [ -z "$out" ]
}

@test "read_network_lines: returns rc 0 even when emitting no output" {
    run read_network_lines
    [ "$status" -eq 0 ]
}

# ---- Network section: rendered output (full + compact layouts) ------------

@test "snapshot: omits Network section when no managed iface is connected" {
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    if echo "$output" | grep -q 'Network'; then
        false
    fi
}

@test "snapshot: shows Network section with eth + wifi rows" {
    printf 'end0:ethernet:connected\nwlan0:wifi:connected\n' > "$TMP/nmcli-dev-status"
    write_eth_speed end0 1000
    printf '*:78:MyHome\n' > "$TMP/nmcli-dev-wifi-wlan0"
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    [[ "$output" == *Network* ]]
    [[ "$output" == *"end0: 1 Gbps"* ]]
    [[ "$output" == *"wlan0: MyHome 78%"* ]]
}

@test "snapshot: failed wifi surfaces WIFI_PASS hint in the Network section" {
    printf 'wlan0:wifi:failed\n' > "$TMP/nmcli-dev-status"
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    [[ "$output" == *"wlan0: failed (WIFI_PASS?)"* ]]
}

@test "snapshot: long SSID is truncated and panel rows stay ≤ STATUS_PANEL_WIDTH" {
    # 64-char SSID forces the compact-panel truncation path. After ANSI
    # strip every visible line must remain inside the 80-col side-by-side
    # frame (status panel + 40-col logo + 2-col gutter); a regression
    # where the indent isn't counted toward _compact_truncate's budget
    # would push the Network row past 80.
    local long_ssid
    long_ssid="$(printf 'X%.0s' {1..64})"
    printf 'wlan0:wifi:connected\n' > "$TMP/nmcli-dev-status"
    printf '*:78:%s\n' "$long_ssid" > "$TMP/nmcli-dev-wifi-wlan0"
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    width="$(printf '%s' "$output" | strip_ansi | max_display_width)"
    (( width <= 80 ))
}

@test "build_status_lines_compact: every Network row is ≤ STATUS_PANEL_WIDTH cells" {
    printf 'wlan0:wifi:connected\n' > "$TMP/nmcli-dev-status"
    local long_ssid
    long_ssid="$(printf 'X%.0s' {1..64})"
    printf '*:78:%s\n' "$long_ssid" > "$TMP/nmcli-dev-wifi-wlan0"
    collect_status_data snapshot
    build_status_lines_compact
    # Find rows that belong to the Network section (header + indented rows
    # following it) and assert each is within the panel width budget.
    local saw_network=0 row stripped
    for row in "${STATUS_LINES[@]}"; do
        stripped="$(printf '%s' "$row" | strip_ansi)"
        case "$stripped" in
            Network) saw_network=1 ;;
        esac
        if (( saw_network )); then
            (( ${#stripped} <= STATUS_PANEL_WIDTH ))
        fi
    done
    (( saw_network ))
}

@test "build_status_lines_full: joined Network row stays ≤ 80 cells for the common case" {
    printf 'end0:ethernet:connected\nwlan0:wifi:connected\n' > "$TMP/nmcli-dev-status"
    write_eth_speed end0 1000
    printf '*:78:MyHome\n' > "$TMP/nmcli-dev-wifi-wlan0"
    collect_status_data snapshot
    build_status_lines_full snapshot
    # Locate the Network row and verify it stayed on one line within 80 cells.
    local row stripped saw=0
    for row in "${STATUS_LINES[@]}"; do
        stripped="$(printf '%s' "$row" | strip_ansi)"
        if [[ "$stripped" == Network*end0* ]]; then
            saw=1
            (( ${#stripped} <= 80 ))
            [[ "$stripped" == *"end0: 1 Gbps"*"wlan0: MyHome 78%"* ]]
        fi
    done
    (( saw ))
}

@test "build_status_lines_full: overflow triggers multi-row fallback" {
    # Two wifi adapters with sanitize-clamp-length SSIDs push the joined
    # row past the 68-char value budget (sanitize clamps a single SSID at
    # 32 chars so we need ≥2 lines to overflow). Fallback should emit a
    # bare "Network" header with iface rows underneath.
    cat > "$TMP/nmcli-dev-status" <<'EOF'
wlan0:wifi:connected
wlan1:wifi:connected
EOF
    local ssid_a ssid_b
    ssid_a="$(printf 'a%.0s' {1..32})"
    ssid_b="$(printf 'b%.0s' {1..32})"
    printf '*:78:%s\n' "$ssid_a" > "$TMP/nmcli-dev-wifi-wlan0"
    printf '*:65:%s\n' "$ssid_b" > "$TMP/nmcli-dev-wifi-wlan1"
    collect_status_data snapshot
    build_status_lines_full snapshot
    # The header row must exist as a bare "Network" line.
    local header_seen=0 row stripped
    for row in "${STATUS_LINES[@]}"; do
        stripped="$(printf '%s' "$row" | strip_ansi)"
        if [[ "$stripped" == "Network" ]]; then
            header_seen=1
        fi
    done
    (( header_seen ))
}
