#!/usr/bin/env bats

# Unit tests for runtime-overlay/src/lib/airplanes/render-status.
# Sources the script for direct access to helpers; the BASH_SOURCE guard at
# the bottom of render-status suppresses dispatcher execution on source.

bats_require_minimum_version 1.5.0

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../runtime-overlay/src/lib/airplanes/render-status"
    LOGO="$BATS_TEST_DIRNAME/../../runtime-overlay/src/share/airplanes/logo.txt"
    BANNER="$BATS_TEST_DIRNAME/../../runtime-overlay/src/share/airplanes/banner.txt"
    BANNER_NARROW="$BATS_TEST_DIRNAME/../../runtime-overlay/src/share/airplanes/banner-narrow.txt"
    ICON="$BATS_TEST_DIRNAME/../../runtime-overlay/src/share/airplanes/icon.txt"
    TMP="$(mktemp -d)"
    # Pin the random tagline index so every snapshot test sees the same
    # string. Must be exported before the `source "$SCRIPT"` below — the
    # tagline pick happens at script load.
    export AIRPLANES_STATUS_TAGLINE_INDEX=0

    # All PATHS_* default to /nonexistent so an un-overridden test gets the
    # "all sources missing" baseline. Individual tests then point a single
    # PATHS_* at a fixture.
    export PATHS_FEEDER_ID="$TMP/nx-feeder-id"
    export PATHS_RELEASE_CHANNEL="$TMP/nx-channel"
    export PATHS_MANIFEST="$TMP/nx-manifest"
    export PATHS_CLAIM_SECRET="$TMP/nx-claim-secret"
    export PATHS_CLAIM_PENDING="$TMP/nx-claim-pending"
    export PATHS_CLAIM_VERSION="$TMP/nx-claim-version"
    export PATHS_AIRCRAFT_JSON="$TMP/nx-aircraft"
    export PATHS_READSB_STATS="$TMP/nx-readsb-stats"
    export PATHS_THERMAL="$TMP/nx-thermal"
    export PATHS_LOGO="$LOGO"
    export PATHS_BANNER="$BANNER"
    export PATHS_BANNER_NARROW="$BANNER_NARROW"
    export PATHS_ICON="$ICON"
    # State-file paths default to non-existent so the defensive
    # `airplanes_read_state() { return 1; }` stub kicks in. Tests that
    # exercise the state-file path call `setup_mlat_state_test_env` to
    # install a working stub and point PATHS_STATE_FILE_MLAT at a fixture.
    export PATHS_STATE_FILE_MLAT="$TMP/nx-mlat-state"
    export PATHS_STATE_FILE_FEED="$TMP/nx-feed-state"
    export PATHS_STATE_FILE_978="$TMP/nx-978-state"
    export PATHS_STATE_FILE_DUMP978FA="$TMP/nx-dump978fa-state"
    export PATHS_STATE_READER_LIB="$TMP/nx-state-reader-lib"
    export PATHS_FEED_ENV="$TMP/nx-feed-env"
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

# Install a `nmcli` shim that dispatches on argv. Mirrors the argv that
# render-status actually emits — `--rescan no` follows `dev wifi list`
# because nmcli 1.52+ rejects the global-flag form.
#   - "-t -f DEVICE,TYPE,STATE dev status"
#         → cat $TMP/nmcli-dev-status
#   - "-t -f IN-USE,SIGNAL,SSID dev wifi list ifname <iface> --rescan no"
#         → cat $TMP/nmcli-dev-wifi-<iface>
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
    "-t -f IN-USE,SIGNAL,SSID dev wifi list ifname "*" --rescan no")
        # Extract the iface that sits between "ifname" and "--rescan".
        # \${@: -3} is the last three args: "<iface> --rescan no".
        set -- \${@: -3}
        iface="\$1"
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
    # write_mlat_state <decision> <reason> [extra=value ...]
    local decision="$1" reason="$2"
    shift 2
    mkdir -p "$(dirname "$PATHS_STATE_FILE_MLAT")"
    {
        printf 'schema_version=1\n'
        printf 'service=airplanes-mlat\n'
        printf 'state=%s\n' "$decision"
        printf 'reason=%s\n' "$reason"
        local kv
        for kv in "$@"; do
            printf '%s\n' "$kv"
        done
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
    PATHS_STATE_FILE_MLAT="$TMP/run/airplanes/mlat/state"
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

@test "mlat_config_state: active + state=disabled,reason=geo_not_configured" {
    setup_mlat_state_test_env
    write_mlat_state disabled geo_not_configured
    run mlat_config_state active
    [ "$output" = 'disabled geo_not_configured' ]
}

@test "mlat_config_state: active + state=misconfigured,reason=mlat_private_invalid" {
    setup_mlat_state_test_env
    write_mlat_state misconfigured mlat_private_invalid
    run mlat_config_state active
    [ "$output" = 'misconfigured mlat_private_invalid' ]
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
    write_mlat_state misconfigured mlat_private_invalid
    stub_systemctl failed 64
    run mlat_config_state failed
    [ "$output" = 'misconfigured mlat_private_invalid' ]
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

# ---- _compute_mlat_note (drives SD_MLAT_NOTE from daemon state) ------------

@test "_compute_mlat_note: mlat_enabled_false + geo_configured=false -> location call-to-action" {
    setup_mlat_state_test_env
    write_mlat_state disabled mlat_enabled_false geo_configured=false
    _compute_mlat_note active
    [ "$SD_MLAT_NOTE" = "Set lat/lon/alt to enable MLAT." ]
}

@test "_compute_mlat_note: mlat_enabled_false + geo_configured=true -> passive disabled note" {
    setup_mlat_state_test_env
    write_mlat_state disabled mlat_enabled_false geo_configured=true
    _compute_mlat_note active
    [ "$SD_MLAT_NOTE" = "MLAT disabled in config." ]
}

@test "_compute_mlat_note: mlat_enabled_false + geo_configured missing -> location call-to-action" {
    setup_mlat_state_test_env
    write_mlat_state disabled mlat_enabled_false
    _compute_mlat_note active
    [ "$SD_MLAT_NOTE" = "Set lat/lon/alt to enable MLAT." ]
}

@test "_compute_mlat_note: geo_not_configured -> location call-to-action" {
    setup_mlat_state_test_env
    write_mlat_state disabled geo_not_configured
    _compute_mlat_note active
    [ "$SD_MLAT_NOTE" = "Set lat/lon/alt to enable MLAT." ]
}

@test "_compute_mlat_note: enabled -> empty note" {
    setup_mlat_state_test_env
    write_mlat_state enabled ok
    _compute_mlat_note active
    [ -z "$SD_MLAT_NOTE" ]
}

@test "_compute_mlat_note: misconfigured -> error note" {
    setup_mlat_state_test_env
    write_mlat_state misconfigured mlat_private_invalid
    _compute_mlat_note active
    [ "$SD_MLAT_NOTE" = "MLAT misconfigured." ]
}

@test "_compute_mlat_note: inactive (no state file) -> empty note (no feed.env fallback)" {
    setup_mlat_state_test_env
    _compute_mlat_note inactive
    [ -z "$SD_MLAT_NOTE" ]
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
    # Banner header: airplanes.live + tagline (index 0) + feed version.
    [[ "$output" == *"airplanes.live"* ]]
    [[ "$output" == *"Unfiltered flight data"* ]]
    [[ "$output" == *"feed sha="* ]]
    [[ "$output" == *Access* ]]
    [[ "$output" == *"Feeder ID"* ]]
    [[ "$output" == *Claim* ]]
    [[ "$output" == *Services* ]]
    [[ "$output" == *Feed* ]]
    [[ "$output" == *System* ]]
}

@test "snapshot: omits the Build line (folded into banner header)" {
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    # The pre-refactor compact panel printed "Build channel=..."; the new
    # banner header carries the version so the compact Feed/System block
    # never re-shows it. Match the leading "Build" label (with at least
    # one trailing space) to avoid matching "Builds" or build-manifest
    # text that might land elsewhere.
    ! grep -q 'Build  *channel=' <<<"$output"
}

@test "snapshot: omits 'sudo apl-feed claim register' hint" {
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    ! grep -q 'sudo apl-feed claim register' <<<"$output"
}

@test "snapshot: surfaces friendly service labels (one row per service)" {
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    [[ "$output" == *"Data upload (feed)"* ]]
    [[ "$output" == *"Aircraft triangulation (mlat)"* ]]
    [[ "$output" == *"ADS-B decoder (readsb)"* ]]
    [[ "$output" == *"UAT receiver (978)"* ]]
}

@test "snapshot: does not render dump978-fa.service as a standalone row" {
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    # The producer unit folds into the UAT receiver row; it must never
    # appear as its own labelled line.
    ! grep -q 'dump978-fa' <<<"$output"
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
    MOTD_WRAPPER="$BATS_TEST_DIRNAME/../../runtime-overlay/src/etc/update-motd.d/10-airplanes-status"
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
    MOTD_WRAPPER="$BATS_TEST_DIRNAME/../../runtime-overlay/src/etc/update-motd.d/10-airplanes-status"
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

@test "snapshot: banner-stack places icon + box above the status block" {
    # New layout (cols >= 80): render_snapshot_banner_stack prints
    # `${icon[i]}  ${box[box_idx]}` per banner row, then a blank line,
    # then the status block flush left. Verify:
    #   - the first output row carries the icon (non-space prefix), and
    #   - "Feeder ID" lives on its own row in the status block (line
    #     starts with the bold-escape + the label at byte 0 of the
    #     ANSI-stripped form).
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    first_line="$(printf '%s' "$output" | head -n1)"
    # Icon column on the first row: non-whitespace within the first
    # ICON_WIDTH cells.
    [[ "${first_line:0:20}" =~ [^[:space:]] ]]
    # Feeder ID row starts flush left (after ANSI strip).
    fid_line="$(printf '%s' "$output" | strip_ansi | grep -m1 'Feeder ID' || true)"
    [ -n "$fid_line" ]
    [[ "$fid_line" =~ ^Feeder\ ID ]]
}

@test "snapshot: banner-stack box contains title, tagline, and build line" {
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    plain="$(printf '%s' "$output" | strip_ansi)"
    # Top border + bottom border + a divider between title/tagline and
    # the build row. Each border line should contain box-drawing glyphs.
    [[ "$plain" == *"┌"* ]]
    [[ "$plain" == *"└"* ]]
    [[ "$plain" == *"├"* ]]
    # Title + tagline + build are inside the box rows.
    [[ "$plain" == *"airplanes.live"* ]]
    [[ "$plain" == *"Unfiltered flight data"* ]]
    [[ "$plain" == *"feed sha="* ]]
}

@test "snapshot: every output line is <= 80 display cells" {
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    width="$(printf '%s' "$output" | strip_ansi | max_display_width)"
    (( width <= 80 ))
}

@test "snapshot: renders the full UUID feeder ID (not just a prefix)" {
    # The legacy compact panel printed the first 8 chars of the UUID; the
    # new banner-stack layout has room for the canonical 36-char form.
    local uuid="70265ea1-aaaa-bbbb-cccc-dddddddddddd"
    printf '%s\n' "$uuid" > "$PATHS_FEEDER_ID"
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    [[ "$output" == *"$uuid"* ]]
}

@test "snapshot: banner box auto-sizes to the build line under channel=stable" {
    # channel=stable is 10 chars including padding; the build line
    # "feed sha=abcdef1 (channel=stable)" is 33 chars. The box must
    # expand to contain it (inner >= 33 + 2*pad). Outer width = inner+2.
    printf '%s\n' "stable" > "$PATHS_RELEASE_CHANNEL"
    cat > "$PATHS_MANIFEST" <<'EOF'
{"components":{"airplanes_feed":"abcdef1234567890abcdef1234567890abcdef12"}}
EOF
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    plain="$(printf '%s' "$output" | strip_ansi)"
    [[ "$plain" == *"feed sha=abcdef1 (channel=stable)"* ]]
    # Top border must be long enough that the build row fits inside it.
    top_line="$(printf '%s' "$plain" | grep -m1 '┌')"
    border_inner="${top_line//[^─]/}"
    (( ${#border_inner} >= 33 + 4 ))
}

@test "snapshot: Access section spills .local URL onto an indented continuation row" {
    # When the host gets an IPv4 + .local URL, the banner-stack layout
    # prints `Access      <ip>` then `            <hostname>.local` —
    # consistent 12-cell label column, no joined comma row.
    printf 'feeder1\n' > "$TMP/hostname-fixture"
    # No hostname mock available; instead override the URL functions via
    # state files / env. Use the live `read_url_local` by setting
    # $HOSTNAME — read_url_local falls back to `hostname` otherwise.
    HOSTNAME=feeder1 run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    plain="$(printf '%s' "$output" | strip_ansi)"
    # The Access label appears once with the IP, the continuation row
    # starts with the 12-cell indent and the .local URL.
    [[ "$plain" =~ Access[[:space:]]+http://[0-9] ]]
    [[ "$plain" =~ $'\n'"            http://"[a-zA-Z0-9-]+\.local ]]
}

@test "snapshot: hardware-health summary in the new builder is truncated to fit 80 cols" {
    # 100-char ASCII summary; the snapshot builder must clamp it so the
    # Hardware row is <= 80 display cells after the 12-cell label.
    local stub long
    stub="$TMP/hardware-long"
    long="$(printf 'X%.0s' {1..100})"
    cat > "$stub" <<EOF
#!/bin/bash
printf 'warn\t%s\n' "$long"
EOF
    chmod +x "$stub"
    PATHS_PIHEALTH_BIN="$stub" run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    plain="$(printf '%s' "$output" | strip_ansi)"
    hw_line="$(printf '%s' "$plain" | grep -m1 '^Hardware ')"
    [ -n "$hw_line" ]
    (( ${#hw_line} <= 80 ))
    # Ellipsis is the truncation signal.
    [[ "$hw_line" == *"..."* ]]
}

@test "snapshot: missing icon degrades to box-only banner without crashing" {
    # The icon ships at PATHS_ICON; pointing at a non-existent path
    # exercises the load_artwork failure branch in
    # render_snapshot_banner_stack. The box must still render and the
    # status block must still print below.
    PATHS_ICON="$TMP/nx-icon" run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    plain="$(printf '%s' "$output" | strip_ansi)"
    [[ "$plain" == *"airplanes.live"* ]]
    [[ "$plain" == *"┌"* ]]
    [[ "$plain" == *"Feeder ID"* ]]
}

@test "once: clears the screen and renders the same banner-stack as --snapshot" {
    # --once differs from --snapshot only in the leading \e[2J\e[H clear.
    # After stripping that prefix, the content should match the snapshot.
    snap="$(bash "$SCRIPT" --snapshot)"
    once="$(bash "$SCRIPT" --once)"
    # The clear is the first thing emitted; trim it.
    once_trimmed="$(printf '%s' "$once" | sed $'s/^\\x1b\\[2J\\x1b\\[H//')"
    [ "$snap" = "$once_trimmed" ]
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

@test "render_banner_stack: missing wide banner falls back to narrow banner" {
    PATHS_BANNER="$TMP/nx-banner"
    declare -a STATUS_LINES=("status-marker")
    out="$(render_banner_stack)"
    width="$(printf '%s' "$out" | strip_ansi | max_display_width)"
    # Narrow banner is BANNER_NARROW_WIDTH=74 cells wide.
    [ "$width" = "74" ]
    [[ "$out" == *status-marker* ]]
}

@test "render_banner_stack: missing wide+narrow banner falls back to logo" {
    PATHS_BANNER="$TMP/nx-banner"
    PATHS_BANNER_NARROW="$TMP/nx-banner-narrow"
    declare -a STATUS_LINES=("status-marker")
    out="$(render_banner_stack)"
    width="$(printf '%s' "$out" | strip_ansi | max_display_width)"
    # Logo is LOGO_WIDTH=40 cells wide.
    [ "$width" = "40" ]
    [[ "$out" == *status-marker* ]]
}

@test "render_banner_narrow_stack: emits 74-col banner lines + status content" {
    declare -a STATUS_LINES=("status-marker")
    out="$(render_banner_narrow_stack)"
    width="$(printf '%s' "$out" | strip_ansi | max_display_width)"
    [ "$width" = "74" ]
    [[ "$out" == *status-marker* ]]
}

@test "render_banner_narrow_stack: missing narrow banner falls back to logo" {
    PATHS_BANNER_NARROW="$TMP/nx-banner-narrow"
    declare -a STATUS_LINES=("status-marker")
    out="$(render_banner_narrow_stack)"
    width="$(printf '%s' "$out" | strip_ansi | max_display_width)"
    [ "$width" = "40" ]
    [[ "$out" == *status-marker* ]]
}

@test "snapshot with missing icon: degrades to text-header + status without crashing" {
    PATHS_ICON="$TMP/nx-missing-icon"
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    # Banner header still renders (icon column just collapses); status
    # panel below stays intact.
    [[ "$output" == *"airplanes.live"* ]]
    [[ "$output" == *"feed sha="* ]]
    [[ "$output" == *Access* ]]
    [[ "$output" == *"Feeder ID"* ]]
    [[ "$output" == *Services* ]]
}

@test "live with missing banner: dispatch keeps narrow tier" {
    # In bats `run` term_cols=80 (no TTY), so the dispatcher takes
    # render_banner_narrow_stack (cols >= BANNER_NARROW_WIDTH but
    # < BANNER_WIDTH) regardless of wide-banner presence. The narrow
    # banner is loaded from the real shipped fixture; here we just
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

# Producer-side fixture: dump978-fa.sh writes /run/airplanes/dump978-fa/state.
# _978_config_state picks this path when the unit is dump978-fa.service.
write_dump978fa_state() {
    local decision="$1" reason="$2"
    mkdir -p "$(dirname "$PATHS_STATE_FILE_DUMP978FA")"
    {
        printf 'schema_version=1\n'
        printf 'service=dump978-fa\n'
        printf 'state=%s\n' "$decision"
        printf 'reason=%s\n' "$reason"
    } > "$PATHS_STATE_FILE_DUMP978FA"
}

setup_978_state_test_env() {
    install_state_reader_stub
    PATHS_STATE_FILE_978="$TMP/run/airplanes/978/state"
    PATHS_STATE_FILE_DUMP978FA="$TMP/run/airplanes/dump978-fa/state"
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
    # Do NOT write either state file — race window where the wrapper
    # exited 64 before publishing state.
    stub_systemctl_978 failed 64
    run _978_config_state failed airplanes-978.service
    [ "$output" = 'misconfigured unknown' ]
}

@test "_978_config_state: dump978-fa reads /run/airplanes/dump978-fa/state (not airplanes-978's)" {
    setup_978_state_test_env
    # Different states in the two files; the unit-name dispatch must pick
    # the right one so a producer-side decision doesn't mask the consumer
    # tile (or vice versa).
    write_978_state         enabled  ok
    write_dump978fa_state   disabled no_hardware
    stub_systemctl_978 failed 64
    run _978_config_state failed dump978-fa.service
    [ "$output" = 'disabled no_hardware' ]
}

@test "_978_config_state: airplanes-978 reads /run/airplanes/978/state (peer_no_hardware refinement)" {
    setup_978_state_test_env
    write_978_state         enabled  peer_no_hardware
    write_dump978fa_state   disabled no_hardware
    stub_systemctl_978 active 0
    run _978_config_state active airplanes-978.service
    [ "$output" = 'enabled peer_no_hardware' ]
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
    # uat_disabled is the producer file too (UAT off in config), so write
    # to the dump978-fa state file for unit-name correctness.
    write_dump978fa_state disabled uat_disabled
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

# ---- New wait/idle synthetic states for no-hardware paths ----------------

@test "unit_state_with_reason: dump978-fa failed + exit-64 + state=disabled,reason=no_hardware → 'wait no_hardware'" {
    setup_978_state_test_env
    write_dump978fa_state disabled no_hardware
    stub_systemctl_978 failed 64
    run unit_state_with_reason dump978-fa.service
    [ "$output" = 'wait no_hardware' ]
}

@test "unit_state_with_reason: airplanes-978 active + state=enabled,reason=peer_no_hardware → 'idle peer_no_hardware'" {
    setup_978_state_test_env
    write_978_state enabled peer_no_hardware
    stub_systemctl_978 active 0
    run unit_state_with_reason airplanes-978.service
    [ "$output" = 'idle peer_no_hardware' ]
}

# ---- svc_token_text: plain-text token for each classifier -----------------

@test "svc_token_text: ok → 'OK'"                       { [ "$(svc_token_text ok)" = 'OK' ]; }
@test "svc_token_text: fail → 'FAIL'"                   { [ "$(svc_token_text fail)" = 'FAIL' ]; }
@test "svc_token_text: misconfigured → '!!'"            { [ "$(svc_token_text misconfigured)" = '!!' ]; }
@test "svc_token_text: masked → 'MASK'"                 { [ "$(svc_token_text masked)" = 'MASK' ]; }
@test "svc_token_text: disabled → 'off'"                { [ "$(svc_token_text disabled)" = 'off' ]; }
@test "svc_token_text: disabled-by-config → 'off'"      { [ "$(svc_token_text disabled-by-config)" = 'off' ]; }
@test "svc_token_text: wait → 'no SDR'"                 { [ "$(svc_token_text wait)" = 'no SDR' ]; }
@test "svc_token_text: idle → 'idle'"                   { [ "$(svc_token_text idle)" = 'idle' ]; }
@test "svc_token_text: partial → 'partial'"             { [ "$(svc_token_text partial)" = 'partial' ]; }
@test "svc_token_text: unknown/timeout/other → '?'" {
    [ "$(svc_token_text unknown)" = '?' ]
    [ "$(svc_token_text timeout)" = '?' ]
    [ "$(svc_token_text bogus-state)" = '?' ]
}

# ---- _978_combined_state matrix: consumer + producer → combined classifier
#
# Helper closes over local consumer/producer state by overriding unit_state
# in the test's shell. The setup-level `source "$SCRIPT"` exposed the
# function, and Bash's last-definition-wins rule means the override here
# takes precedence inside the test body.
_978_stub_states() {
    local consumer="$1" producer="$2"
    eval "unit_state() {
        case \"\$1\" in
            airplanes-978.service) printf '%s' '$consumer' ;;
            dump978-fa.service)    printf '%s' '$producer' ;;
            *)                     printf 'unknown' ;;
        esac
    }"
}

@test "_978_combined_state: both ok → ok" {
    _978_stub_states ok ok
    [ "$(_978_combined_state)" = 'ok' ]
}

@test "_978_combined_state: consumer fail wins over producer ok" {
    _978_stub_states fail ok
    [ "$(_978_combined_state)" = 'fail' ]
}

@test "_978_combined_state: producer fail wins when consumer is healthy" {
    _978_stub_states ok fail
    [ "$(_978_combined_state)" = 'fail' ]
}

@test "_978_combined_state: misconfigured propagates" {
    _978_stub_states misconfigured ok
    [ "$(_978_combined_state)" = 'misconfigured' ]
    _978_stub_states ok misconfigured
    [ "$(_978_combined_state)" = 'misconfigured' ]
}

@test "_978_combined_state: masked propagates" {
    _978_stub_states masked ok
    [ "$(_978_combined_state)" = 'masked' ]
}

@test "_978_combined_state: timeout propagates" {
    _978_stub_states ok timeout
    [ "$(_978_combined_state)" = 'timeout' ]
}

@test "_978_combined_state: unknown wins over off (consumer)" {
    _978_stub_states unknown disabled-by-config
    [ "$(_978_combined_state)" = 'unknown' ]
}

@test "_978_combined_state: unknown wins over off (producer)" {
    _978_stub_states disabled-by-config unknown
    [ "$(_978_combined_state)" = 'unknown' ]
}

@test "_978_combined_state: consumer ok + producer wait → partial" {
    _978_stub_states ok wait
    [ "$(_978_combined_state)" = 'partial' ]
}

@test "_978_combined_state: consumer ok + producer disabled-by-config → partial" {
    _978_stub_states ok disabled-by-config
    [ "$(_978_combined_state)" = 'partial' ]
}

@test "_978_combined_state: consumer idle → idle (producer state ignored)" {
    _978_stub_states idle disabled-by-config
    [ "$(_978_combined_state)" = 'idle' ]
    _978_stub_states idle wait
    [ "$(_978_combined_state)" = 'idle' ]
}

@test "_978_combined_state: consumer off + producer ok → partial" {
    _978_stub_states disabled-by-config ok
    [ "$(_978_combined_state)" = 'partial' ]
}

@test "_978_combined_state: consumer off + producer wait → disabled-by-config" {
    _978_stub_states disabled-by-config wait
    [ "$(_978_combined_state)" = 'disabled-by-config' ]
}

@test "_978_combined_state: both disabled-by-config → disabled-by-config" {
    _978_stub_states disabled-by-config disabled-by-config
    [ "$(_978_combined_state)" = 'disabled-by-config' ]
}

@test "_978_combined_state: 'disabled' (non-config) is treated like off in either slot" {
    # unit_state's generic UnitFileState=disabled fallback emits 'disabled'
    # (not 'disabled-by-config'). The combined matrix must treat it the
    # same as disabled-by-config — otherwise a feeder running on the
    # cache-miss fallback path would render UAT as 'unknown'.
    _978_stub_states disabled ok
    [ "$(_978_combined_state)" = 'partial' ]
    _978_stub_states ok disabled
    [ "$(_978_combined_state)" = 'partial' ]
    _978_stub_states disabled wait
    [ "$(_978_combined_state)" = 'disabled-by-config' ]
    _978_stub_states disabled disabled
    [ "$(_978_combined_state)" = 'disabled-by-config' ]
}

# Cartesian guard: with every consumer/producer pairing across the full
# classifier vocabulary, only the literal (ok, ok) pair is allowed to
# resolve to the green 'ok' token. Catches a regression that adds a new
# state to unit_state without updating the matrix and silently flips
# UAT to green when it shouldn't.
@test "_978_combined_state: only (ok,ok) returns 'ok' across the full state vocabulary" {
    local states=(ok fail masked misconfigured disabled disabled-by-config wait idle unknown timeout)
    local c p result
    for c in "${states[@]}"; do
        for p in "${states[@]}"; do
            _978_stub_states "$c" "$p"
            result="$(_978_combined_state)"
            if [[ "$c" == ok && "$p" == ok ]]; then
                [ "$result" = 'ok' ] || {
                    printf 'expected ok for (ok, ok), got %s\n' "$result" >&2
                    return 1
                }
            else
                [ "$result" != 'ok' ] || {
                    printf '(%s, %s) silently rendered ok\n' "$c" "$p" >&2
                    return 1
                }
            fi
        done
    done
}

# ---- render_snapshot_with_header: icon-threshold boundary ------------------

@test "render_snapshot_with_header: at exactly SNAPSHOT_ICON_MIN_COLS the icon column appears" {
    STATUS_LINES=("status-marker")
    out="$(render_snapshot_with_header "$SNAPSHOT_ICON_MIN_COLS")"
    # The icon's first row has a non-space character; verify the line
    # containing "status-marker" has a non-empty, non-whitespace prefix.
    line="$(printf '%s' "$out" | grep -m1 'status-marker' || true)"
    [ -n "$line" ]
    prefix="${line%%status-marker*}"
    [[ "$prefix" =~ [^[:space:]] ]]
}

@test "render_snapshot_with_header: just below SNAPSHOT_ICON_MIN_COLS drops the icon" {
    STATUS_LINES=("status-marker")
    out="$(render_snapshot_with_header "$(( SNAPSHOT_ICON_MIN_COLS - 1 ))")"
    line="$(printf '%s' "$out" | grep -m1 'status-marker' || true)"
    [ -n "$line" ]
    # No icon column → status-marker starts at the line's first cell
    # (after the leading newline that printf already consumed).
    [[ "$line" =~ ^status-marker ]]
}

@test "AIRPLANES_STATUS_TAGLINE_INDEX=08 (leading zero) does not leak a stderr error" {
    err="$(AIRPLANES_STATUS_TAGLINE_INDEX=08 bash "$SCRIPT" --snapshot 2>&1 >/dev/null)"
    # Pre-fix: `$(( 08 ))` would print "value too great for base (error
    # token is "08")" to stderr; that text would land in the MOTD.
    [[ ! "$err" =~ "value too great" ]] || {
        printf 'octal error leaked: %s\n' "$err" >&2
        return 1
    }
}

# ---- service_display_state: id → classifier --------------------------------

@test "service_display_state: known ids dispatch to the right backend" {
    unit_state() {
        case "$1" in
            airplanes-feed.service) printf 'ok' ;;
            airplanes-mlat.service) printf 'disabled-by-config' ;;
            readsb.service)         printf 'fail' ;;
            *)                      printf 'unknown' ;;
        esac
    }
    [ "$(service_display_state feed)" = 'ok' ]
    [ "$(service_display_state mlat)" = 'disabled-by-config' ]
    [ "$(service_display_state readsb)" = 'fail' ]
}

@test "service_display_state: unknown id → 'unknown'" {
    [ "$(service_display_state nonsense)" = 'unknown' ]
}

# ---- display_service_rows: end-to-end row formatting -----------------------

@test "display_service_rows: emits one labelled row per display service" {
    _978_stub_states disabled-by-config disabled-by-config
    # All other units fall through to the _978_stub_states unit_state
    # function which returns 'unknown' for non-978 services.
    out="$(display_service_rows '  ')"
    n="$(printf '%s\n' "$out" | wc -l)"
    [ "$n" -eq 4 ]
    grep -q 'Data upload (feed)' <<<"$out"
    grep -q 'Aircraft triangulation (mlat)' <<<"$out"
    grep -q 'ADS-B decoder (readsb)' <<<"$out"
    grep -q 'UAT receiver (978)' <<<"$out"
    # Combined off renders as 'off' (disabled token); not 'OK'.
    grep -q 'UAT receiver (978).*off' <<<"$out"
}

# ---- tagline-index override: deterministic snapshot output -----------------

@test "AIRPLANES_STATUS_TAGLINE_INDEX clamps deterministic tagline" {
    # setup() pins index 0 already. Sanity-check the mechanism by
    # asserting the snapshot output contains the index-0 string and not
    # any other tagline.
    run bash "$SCRIPT" --snapshot
    [[ "$output" == *"Unfiltered flight data"* ]]
    ! grep -q 'Signal desk' <<<"$output"
}

# ---- icon artwork ships at the documented width ---------------------------

@test "load_artwork: icon.txt is 20 cols × non-empty" {
    declare -a art=()
    load_artwork "$PATHS_ICON" "$ICON_WIDTH" art
    rc=$?
    [ "$rc" -eq 0 ]
    [ "${#art[@]}" -gt 0 ]
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

@test "_nm_dev_wifi_list: --rescan no must follow the dev-wifi-list subcommand" {
    # Regression for the silent-no-WiFi-row bug on nmcli 1.52+: putting
    # --rescan in the global-flag position (before `dev wifi list`)
    # makes nmcli exit 2 with "Option '--rescan' is unknown", which
    # render-status swallowed via 2>/dev/null. The default test stub
    # doesn't care about argv ordering, so we install a strict shim
    # that emulates real nmcli's argument parsing.
    local shim="$TMP/shim-nmcli-strict"
    mkdir -p "$shim"
    cat > "$shim/nmcli" <<'EOF'
#!/bin/bash
# Reject --rescan in the global position (before `dev`).
i=1
for arg in "$@"; do
    if [ "$arg" = "dev" ]; then
        break
    fi
    if [ "$arg" = "--rescan" ]; then
        echo "Option '--rescan' is unknown, try 'nmcli -help'." >&2
        exit 2
    fi
    i=$((i + 1))
done
# Otherwise, emit a canned in-use row so the caller can confirm it ran.
echo "*:78:RegressionNet"
exit 0
EOF
    chmod +x "$shim/nmcli"
    PATH="$shim:$PATH"

    run _nm_dev_wifi_list wlan0
    [ "$status" -eq 0 ]
    [ "$output" = "*:78:RegressionNet" ]
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

# --- backend endpoint brackets (non-default backends) ------------------------

setup_feed_state_test_env() {
    install_state_reader_stub
    PATHS_STATE_FILE_FEED="$TMP/run/airplanes/feed/state"
}

# write_feed_state_endpoint <host> <port> <is_default>
write_feed_state_endpoint() {
    mkdir -p "$(dirname "$PATHS_STATE_FILE_FEED")"
    {
        printf 'schema_version=1\n'
        printf 'service=airplanes-feed\n'
        printf 'state=enabled\n'
        printf 'reason=ok\n'
        printf 'target_host=%s\n' "$1"
        printf 'target_port=%s\n' "$2"
        printf 'target_is_default=%s\n' "$3"
    } > "$PATHS_STATE_FILE_FEED"
}

write_feed_env_website() {
    printf 'APL_FEED_WEBSITE_URL=%s\n' "$1" > "$TMP/feed.env"
    PATHS_FEED_ENV="$TMP/feed.env"
}

@test "_derive_feed_target_host: non-default endpoint sets the display host" {
    setup_feed_state_test_env
    write_feed_state_endpoint feed.airplanes.test 30004 false
    _derive_feed_target_host
    [ "$SD_FEED_TARGET_HOST" = "feed.airplanes.test" ]
}

@test "_derive_feed_target_host: default endpoint stays empty" {
    setup_feed_state_test_env
    write_feed_state_endpoint feed.airplanes.live 30004 true
    _derive_feed_target_host
    [ -z "$SD_FEED_TARGET_HOST" ]
}

@test "_derive_feed_target_host: non-default port renders host:port" {
    setup_feed_state_test_env
    write_feed_state_endpoint feed.airplanes.live 9999 false
    _derive_feed_target_host
    [ "$SD_FEED_TARGET_HOST" = "feed.airplanes.live:9999" ]
}

@test "_derive_feed_target_host: invalid (present-but-empty) endpoint stays empty" {
    setup_feed_state_test_env
    write_feed_state_endpoint '' '' ''
    _derive_feed_target_host
    [ -z "$SD_FEED_TARGET_HOST" ]
}

@test "_derive_feed_target_host: missing state file clears a stale value" {
    setup_feed_state_test_env
    SD_FEED_TARGET_HOST="stale.example"
    _derive_feed_target_host
    [ -z "$SD_FEED_TARGET_HOST" ]
}

@test "_derive_website_host: non-default URL sets the display host" {
    write_feed_env_website 'https://web.dev.airplanes.live'
    _derive_website_host
    [ "$SD_WEBSITE_HOST" = "web.dev.airplanes.live" ]
}

@test "_derive_website_host: quoted URL with path parses to the host" {
    write_feed_env_website '"https://airplanes.test/some/path"'
    _derive_website_host
    [ "$SD_WEBSITE_HOST" = "airplanes.test" ]
}

@test "_derive_website_host: default URL stays empty" {
    write_feed_env_website 'https://airplanes.live'
    _derive_website_host
    [ -z "$SD_WEBSITE_HOST" ]
}

@test "_derive_website_host: missing feed.env clears a stale value" {
    SD_WEBSITE_HOST="stale.example"
    _derive_website_host
    [ -z "$SD_WEBSITE_HOST" ]
}

@test "_derive_website_host: host outside the charset stays empty" {
    write_feed_env_website 'https://bad_host;injection'
    _derive_website_host
    [ -z "$SD_WEBSITE_HOST" ]
}

@test "full layout: Claim and Feed rows carry brackets for non-default backends" {
    setup_feed_state_test_env
    write_feed_state_endpoint feed.airplanes.test 30004 false
    write_feed_env_website 'https://web.dev.airplanes.live'
    collect_status_data snapshot
    build_status_lines_full live
    local row claim_ok=0 feed_ok=0
    for row in "${STATUS_LINES[@]}"; do
        case "$(printf '%s' "$row" | strip_ansi)" in
            Claim*'[web.dev.airplanes.live]'*) claim_ok=1 ;;
            Feed\ *'[feed.airplanes.test]'*) feed_ok=1 ;;
        esac
    done
    (( claim_ok )) && (( feed_ok ))
}

@test "snapshot layout: Claim and Feed rows carry brackets for non-default backends" {
    setup_feed_state_test_env
    write_feed_state_endpoint feed.airplanes.test 30004 false
    write_feed_env_website 'https://web.dev.airplanes.live'
    collect_status_data snapshot
    build_status_lines_snapshot
    local row claim_ok=0 feed_ok=0
    for row in "${STATUS_LINES[@]}"; do
        case "$(printf '%s' "$row" | strip_ansi)" in
            Claim*'[web.dev.airplanes.live]'*) claim_ok=1 ;;
            Feed\ *'[feed.airplanes.test]'*) feed_ok=1 ;;
        esac
    done
    (( claim_ok )) && (( feed_ok ))
}

@test "compact layout: brackets land on dim continuation rows within panel width" {
    setup_feed_state_test_env
    write_feed_state_endpoint feed.airplanes.test 30004 false
    write_feed_env_website 'https://web.dev.airplanes.live'
    collect_status_data snapshot
    build_status_lines_compact
    local row stripped ws_ok=0 fh_ok=0
    for row in "${STATUS_LINES[@]}"; do
        stripped="$(printf '%s' "$row" | strip_ansi)"
        case "$stripped" in
            '  [web.dev.airplanes.live]') ws_ok=1 ;;
            '  [feed.airplanes.test]') fh_ok=1 ;;
        esac
        # No bracket may ride inline on the Claim/Feed rows in compact.
        case "$stripped" in
            Claim*'['*|Feed\ *'['*) return 1 ;;
        esac
        (( ${#stripped} <= STATUS_PANEL_WIDTH ))
    done
    (( ws_ok )) && (( fh_ok ))
}

@test "default install: no backend brackets in any layout" {
    collect_status_data snapshot
    local builder row
    for builder in 'build_status_lines_full live' build_status_lines_snapshot build_status_lines_compact; do
        $builder
        for row in "${STATUS_LINES[@]}"; do
            case "$(printf '%s' "$row" | strip_ansi)" in
                Claim*'['*|Feed\ *'['*) return 1 ;;
            esac
        done
    done
}

@test "snapshot layout: bracketed rows stay within 80 cols at the 30-char host clamp" {
    setup_feed_state_test_env
    local long_host
    long_host="$(printf 'h%.0s' {1..60}).example"
    write_feed_state_endpoint "$long_host" 30004 false
    write_feed_env_website "https://$long_host"
    collect_status_data snapshot
    # sanitize(30) caps the display host regardless of feed.env content.
    [ "${#SD_FEED_TARGET_HOST}" -le 30 ]
    [ "${#SD_WEBSITE_HOST}" -le 30 ]
    build_status_lines_snapshot
    local row stripped
    for row in "${STATUS_LINES[@]}"; do
        stripped="$(printf '%s' "$row" | strip_ansi)"
        case "$stripped" in
            Claim*|Feed\ *) (( ${#stripped} <= 80 )) ;;
        esac
    done
}

@test "full layout: MLAT note spills to its own row when the Feed bracket is present" {
    setup_feed_state_test_env
    write_feed_state_endpoint feed.airplanes.test 30004 false
    collect_status_data snapshot
    SD_MLAT_WARN="Set lat/lon/alt to enable MLAT."
    build_status_lines_full live
    local row stripped feed_row="" spill_seen=0
    for row in "${STATUS_LINES[@]}"; do
        stripped="$(printf '%s' "$row" | strip_ansi)"
        case "$stripped" in
            Feed\ *) feed_row="$stripped" ;;
            '            Set lat/lon/alt to enable MLAT.') spill_seen=1 ;;
        esac
    done
    [[ "$feed_row" == *'[feed.airplanes.test]'* ]]
    [[ "$feed_row" != *'MLAT'* ]]
    (( spill_seen ))
    (( ${#feed_row} <= 80 ))
}

@test "full layout: MLAT note stays inline on the Feed row without a bracket" {
    collect_status_data snapshot
    SD_FEED_TARGET_HOST=""
    SD_MLAT_WARN="Set lat/lon/alt to enable MLAT."
    build_status_lines_full live
    local row stripped feed_ok=0
    for row in "${STATUS_LINES[@]}"; do
        stripped="$(printf '%s' "$row" | strip_ansi)"
        case "$stripped" in
            Feed\ *'Set lat/lon/alt to enable MLAT.'*) feed_ok=1 ;;
        esac
    done
    (( feed_ok ))
}

@test "full layout: worst-case bracketed rows stay within 80 cols" {
    setup_feed_state_test_env
    local long_host
    long_host="$(printf 'h%.0s' {1..60}).example"
    write_feed_state_endpoint "$long_host" 30004 false
    write_feed_env_website "https://$long_host"
    collect_status_data snapshot
    SD_MLAT_WARN="Set lat/lon/alt to enable MLAT."
    build_status_lines_full live
    # Measure characters, not bytes — the script's LC_ALL=C would count
    # the claim hint's em-dash as 3, overstating the display width.
    local row stripped
    for row in "${STATUS_LINES[@]}"; do
        stripped="$(printf '%s' "$row" | strip_ansi)"
        case "$stripped" in
            Claim*|Feed\ *)
                local LC_ALL=C.UTF-8
                (( ${#stripped} <= 80 ))
                ;;
        esac
    done
}

# ---- readsb_config_state — same shape as _978_config_state ----------------

write_readsb_state() {
    # write_readsb_state <decision> <reason>
    local decision="$1" reason="$2"
    mkdir -p "$(dirname "$PATHS_STATE_FILE_READSB")"
    {
        printf 'schema_version=1\n'
        printf 'service=readsb\n'
        printf 'state=%s\n' "$decision"
        printf 'reason=%s\n' "$reason"
    } > "$PATHS_STATE_FILE_READSB"
}

setup_readsb_state_test_env() {
    install_state_reader_stub
    PATHS_STATE_FILE_READSB="$TMP/run/readsb/state"
}

@test "readsb_config_state: active + state=enabled,reason=ok" {
    setup_readsb_state_test_env
    write_readsb_state enabled ok
    run readsb_config_state active
    [ "$status" -eq 0 ]
    [ "$output" = 'enabled ok' ]
}

@test "readsb_config_state: active + state=disabled,reason=no_hardware" {
    setup_readsb_state_test_env
    write_readsb_state disabled no_hardware
    run readsb_config_state active
    [ "$output" = 'disabled no_hardware' ]
}

@test "readsb_config_state: active + state file absent → 'unknown -'" {
    setup_readsb_state_test_env
    run readsb_config_state active
    [ "$output" = 'unknown -' ]
}

@test "readsb_config_state: inactive → 'inactive -'" {
    setup_readsb_state_test_env
    write_readsb_state disabled no_hardware
    run readsb_config_state inactive
    [ "$output" = 'inactive -' ]
}

# Integration: a pinned-SDR-absent self-disable (unit active,
# state=disabled/no_hardware) must surface as the amber 'wait' token in the
# tile, not the green ok that systemd-active alone would produce.
@test "unit_state_with_reason readsb: active + no_hardware → 'wait no_hardware'" {
    setup_readsb_state_test_env
    write_readsb_state disabled no_hardware
    SD_UNIT_PROPS_PRIMED=0
    stub_systemctl active 0
    run unit_state_with_reason readsb.service
    [ "$output" = 'wait no_hardware' ]
}

# An active readsb with NO state file (older overlay / pre-first-write) falls
# back to the systemd-derived 'ok', never 'unknown'.
@test "unit_state_with_reason readsb: active + no state file → 'ok -'" {
    setup_readsb_state_test_env
    SD_UNIT_PROPS_PRIMED=0
    stub_systemctl active 0
    run unit_state_with_reason readsb.service
    [ "$output" = 'ok -' ]
}

# ---- effective gain: read_readsb_gain_db -----------------------------------

@test "read_readsb_gain_db: missing file -> non-zero, empty" {
    run read_readsb_gain_db
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "read_readsb_gain_db: numeric gain_db -> one-decimal value" {
    printf '{"gain_db":49.6,"messages":1}\n' > "$PATHS_READSB_STATS"
    [ "$(read_readsb_gain_db)" = "49.6" ]
}

@test "read_readsb_gain_db: integer gain_db normalised to one decimal" {
    printf '{"gain_db":33}\n' > "$PATHS_READSB_STATS"
    [ "$(read_readsb_gain_db)" = "33.0" ]
}

@test "read_readsb_gain_db: JSON string gain_db rejected (numbers type-gate)" {
    printf '{"gain_db":"49.6"}\n' > "$PATHS_READSB_STATS"
    run read_readsb_gain_db
    [ "$status" -ne 0 ]
}

@test "read_readsb_gain_db: null or absent gain_db rejected" {
    printf '{"gain_db":null}\n' > "$PATHS_READSB_STATS"
    run read_readsb_gain_db
    [ "$status" -ne 0 ]
    printf '{"messages":1}\n' > "$PATHS_READSB_STATS"
    run read_readsb_gain_db
    [ "$status" -ne 0 ]
}

@test "read_readsb_gain_db: out-of-range dropped, boundary kept" {
    printf '{"gain_db":99}\n' > "$PATHS_READSB_STATS"
    [ "$(read_readsb_gain_db)" = "99.0" ]
    printf '{"gain_db":100}\n' > "$PATHS_READSB_STATS"
    run read_readsb_gain_db
    [ "$status" -ne 0 ]
    printf '{"gain_db":-10}\n' > "$PATHS_READSB_STATS"
    run read_readsb_gain_db
    [ "$status" -ne 0 ]
}

@test "read_readsb_gain_db: malformed JSON rejected" {
    printf 'not json' > "$PATHS_READSB_STATS"
    run read_readsb_gain_db
    [ "$status" -ne 0 ]
}

# ---- effective gain: collect_status_data gating ----------------------------
#
# Prime readsb's ActiveState via the systemctl-show shim so the gate's
# `_unit_prop readsb.service ActiveState` resolves from the per-frame cache.

_gain_prime_readsb() {
    local active="${1:-active}"
    local shim
    shim="$(_systemctl_show_shim)"
    PATH="$shim:$PATH"
    cat > "$TMP/sysctl-show.out" <<EOF
Id=readsb.service
ActiveState=$active
UnitFileState=enabled
ExecMainStatus=0
EOF
}

@test "gain gate: GAIN=auto + readsb active + fresh stats -> SD_GAIN_DB set" {
    _gain_prime_readsb active
    printf 'GAIN=auto\n' > "$PATHS_FEED_ENV"
    printf '{"gain_db":49.6}\n' > "$PATHS_READSB_STATS"
    collect_status_data snapshot
    [ "$SD_GAIN_DB" = "49.6" ]
    [ "$SD_GAIN_CFG" = "auto" ]
}

@test "gain gate: GAIN unset (defaults to auto) still surfaces effective gain" {
    _gain_prime_readsb active
    # No PATHS_FEED_ENV file -> _read_feed_env_value fails -> default auto.
    printf '{"gain_db":40.0}\n' > "$PATHS_READSB_STATS"
    collect_status_data snapshot
    [ "$SD_GAIN_DB" = "40.0" ]
    [ "$SD_GAIN_CFG" = "auto" ]
}

@test "gain gate: numeric GAIN hides effective gain (configured == effective)" {
    _gain_prime_readsb active
    printf 'GAIN=49.6\n' > "$PATHS_FEED_ENV"
    printf '{"gain_db":49.6}\n' > "$PATHS_READSB_STATS"
    collect_status_data snapshot
    [ -z "$SD_GAIN_DB" ]
}

@test "gain gate: readsb inactive hides effective gain" {
    _gain_prime_readsb inactive
    printf 'GAIN=auto\n' > "$PATHS_FEED_ENV"
    printf '{"gain_db":49.6}\n' > "$PATHS_READSB_STATS"
    collect_status_data snapshot
    [ -z "$SD_GAIN_DB" ]
}

@test "gain gate: stale stats.json (>90s) hides effective gain" {
    _gain_prime_readsb active
    printf 'GAIN=auto\n' > "$PATHS_FEED_ENV"
    printf '{"gain_db":49.6}\n' > "$PATHS_READSB_STATS"
    touch -d "@$(( $(date +%s) - 120 ))" "$PATHS_READSB_STATS"
    collect_status_data snapshot
    [ -z "$SD_GAIN_DB" ]
}

# ---- effective gain: builder rows ------------------------------------------

# These call collect_status_data first (populating SD_NETWORK_LINES and the
# rest of the SD_* globals the builders expand under `set -u`), then override
# the gain globals to drive the row directly.

@test "compact builder: gain row present and within 38 cols when SD_GAIN_DB set" {
    _gain_prime_readsb active
    collect_status_data snapshot
    SD_GAIN_DB="49.6"
    SD_GAIN_CFG="auto"
    build_status_lines_compact
    printf '%s\n' "${STATUS_LINES[@]}" | strip_ansi | grep -q '^Gain .*49\.6 dB'
    local w
    w="$(printf '%s\n' "${STATUS_LINES[@]}" | strip_ansi | max_display_width)"
    (( w <= 38 ))
}

@test "compact builder: no gain row when SD_GAIN_DB empty" {
    _gain_prime_readsb active
    collect_status_data snapshot
    SD_GAIN_DB=""
    SD_GAIN_CFG=""
    build_status_lines_compact
    ! printf '%s\n' "${STATUS_LINES[@]}" | strip_ansi | grep -q '^Gain '
}

@test "snapshot builder: gain row shows 'cfg -> db dB'" {
    _gain_prime_readsb active
    collect_status_data snapshot
    SD_GAIN_DB="49.6"
    SD_GAIN_CFG="auto"
    build_status_lines_snapshot
    printf '%s\n' "${STATUS_LINES[@]}" | strip_ansi | grep -q 'Gain .*auto -> 49\.6 dB'
}
