#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031
#
# Tests for apl-wifi (the privileged Wi-Fi management helper invoked by
# webconfig over a sudoers-pinned argv). Every test runs the helper as a
# child process — apl-wifi's subcommands are not sourced — and asserts on
# the JSON envelope it prints to stdout plus its exit code. NetworkManager
# is faked via test/lib/nmcli-stub.

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    HELPER="$REPO_ROOT/stage-airplanes/05-install-webconfig/files/usr/local/bin/apl-wifi"
    LIB_DIR="$REPO_ROOT/stage-airplanes/05-install-webconfig/files/usr/local/lib/airplanes"
    TMP="$(mktemp -d)"

    export APL_WIFI_LIB_DIR="$LIB_DIR"
    export APL_WIFI_KEYFILE_DIR="$TMP/nm"
    export APL_WIFI_LOCK="$TMP/run/wifi.lock"
    export APL_WIFI_ROLLBACK_DIR="$TMP/run/wifi-rollback"
    export APL_WIFI_UUID_SOURCE="$TMP/uuid"
    export APL_WIFI_NMCLI="$BATS_TEST_DIRNAME/lib/nmcli-stub"
    export NMCLI_STUB_LOG="$TMP/nmcli.log"
    mkdir -p "$APL_WIFI_KEYFILE_DIR" "$TMP/run"

    # Fixed UUID for deterministic asserts.
    printf '00000000-0000-4000-8000-000000000000\n' > "$APL_WIFI_UUID_SOURCE"

    : > "$NMCLI_STUB_LOG"
    unset NMCLI_STUB_ACTIVE NMCLI_STUB_UP_EXIT NMCLI_STUB_UP_STDERR \
          NMCLI_STUB_CONN_STATE NMCLI_STUB_CONN_DEVICE \
          NMCLI_STUB_DEV_IP4 NMCLI_STUB_DEV_STATE
}

teardown() { rm -rf "$TMP"; }

# Helper: run apl-wifi <verb> --json with $1 as stdin, capture $output / $status.
# Suppress stderr — bats `run` merges streams; we only assert on the JSON
# envelope that goes to stdout.
run_apl_wifi() {
    local verb="$1" body="${2:-}"
    run bash -c '"$0" "$1" --json <<<"$2" 2>/dev/null' "$HELPER" "$verb" "$body"
}

# Helper: extract a JSON field from $output via jq -r.
out_field() {
    jq -r "$1" <<<"$output"
}

# ---- envelope shape -------------------------------------------------------

@test "list: empty keyfile dir → status ok, networks=[]" {
    run_apl_wifi list ""
    [ "$status" -eq 0 ]
    [ "$(out_field '.status')" = "ok" ]
    [ "$(out_field '.networks | length')" = "0" ]
    [ "$(out_field '.networkmanager_available')" = "true" ]
}

@test "list: surfaces existing first-run keyfile as managed + first_run_profile" {
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-config-wifi.nmconnection" <<EOF
[connection]
id=airplanes-config-wifi
uuid=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
type=wifi
autoconnect=true

[wifi]
ssid=HomeNet
mode=infrastructure

[wifi-security]
key-mgmt=wpa-psk
psk=hunter22hunter22

[ipv4]
method=auto
EOF
    run_apl_wifi list ""
    [ "$status" -eq 0 ]
    [ "$(out_field '.networks | length')" = "1" ]
    [ "$(out_field '.networks[0].id')" = "airplanes-config-wifi" ]
    [ "$(out_field '.networks[0].ssid')" = "HomeNet" ]
    [ "$(out_field '.networks[0].managed')" = "true" ]
    [ "$(out_field '.networks[0].first_run_profile')" = "true" ]
    [ "$(out_field '.networks[0].has_psk')" = "true" ]
}

@test "list: foreign keyfile → managed=false" {
    cat > "$APL_WIFI_KEYFILE_DIR/foreign-net.nmconnection" <<EOF
[connection]
id=foreign-net
uuid=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
type=wifi
autoconnect=true

[wifi]
ssid=ForeignNet
mode=infrastructure

[ipv4]
method=auto
EOF
    run_apl_wifi list ""
    [ "$status" -eq 0 ]
    [ "$(out_field '.networks[0].managed')" = "false" ]
    [ "$(out_field '.networks[0].first_run_profile')" = "false" ]
}

@test "list: active wifi is tagged from nmcli output" {
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-cafe.nmconnection" <<EOF
[connection]
id=cafe
uuid=cccccccc-cccc-4ccc-8ccc-cccccccccccc
type=wifi

[wifi]
ssid=Cafe
EOF
    export NMCLI_STUB_ACTIVE='cccccccc-cccc-4ccc-8ccc-cccccccccccc:802-11-wireless:wlan0'
    run_apl_wifi list ""
    [ "$status" -eq 0 ]
    [ "$(out_field '.networks[0].active')" = "true" ]
    [ "$(out_field '.active_connection.uuid')" = "cccccccc-cccc-4ccc-8ccc-cccccccccccc" ]
}

# ---- add ------------------------------------------------------------------

@test "add: happy path without test writes keyfile and returns applied" {
    run_apl_wifi add '{"ssid":"HomeNet","psk":"hunter22","test":false}'
    [ "$status" -eq 0 ]
    [ "$(out_field '.status')" = "applied" ]
    [ "$(out_field '.id')" = "airplanes-wifi-homenet" ]
    [ "$(out_field '.ssid')" = "HomeNet" ]
    [ -f "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-homenet.nmconnection" ]
    grep -q '^ssid=HomeNet$' "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-homenet.nmconnection"
    grep -q '^psk=hunter22$' "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-homenet.nmconnection"
}

@test "add: keyfile is 0600" {
    run_apl_wifi add '{"ssid":"HomeNet","psk":"hunter22","test":false}'
    [ "$(stat -c %a "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-homenet.nmconnection")" = "600" ]
}

@test "add: open network (no psk) omits wifi-security section" {
    run_apl_wifi add '{"ssid":"OpenNet","test":false}'
    [ "$status" -eq 0 ]
    local f="$APL_WIFI_KEYFILE_DIR/airplanes-wifi-opennet.nmconnection"
    [ -f "$f" ]
    run grep -q '^\[wifi-security\]$' "$f"
    [ "$status" -ne 0 ]
}

@test "add: hidden flag emits hidden=true" {
    run_apl_wifi add '{"ssid":"StealthNet","psk":"hunter22","hidden":true,"test":false}'
    [ "$status" -eq 0 ]
    grep -q '^hidden=true$' "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-stealthnet.nmconnection"
}

@test "add: priority>0 emits autoconnect-priority" {
    run_apl_wifi add '{"ssid":"HomeNet","psk":"hunter22","priority":5,"test":false}'
    [ "$status" -eq 0 ]
    grep -q '^autoconnect-priority=5$' "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-homenet.nmconnection"
}

@test "add: 33-byte SSID rejected with per-field error" {
    local long
    long="$(printf 'a%.0s' {1..33})"
    run_apl_wifi add "{\"ssid\":\"$long\",\"psk\":\"hunter22\",\"test\":false}"
    [ "$status" -eq 2 ]
    [ "$(out_field '.status')" = "rejected" ]
    [ "$(out_field '.errors.ssid')" != "null" ]
}

@test "add: 7-char PSK rejected" {
    run_apl_wifi add '{"ssid":"HomeNet","psk":"1234567","test":false}'
    [ "$status" -eq 2 ]
    [ "$(out_field '.status')" = "rejected" ]
    [ "$(out_field '.errors.psk')" != "null" ]
}

@test "add: PSK with embedded LF rejected" {
    # jq-layer control-byte gate catches this before command substitution
    # has a chance to strip it — works regardless of LF position.
    run_apl_wifi add '{"ssid":"HomeNet","psk":"hunt\ner22","test":false}'
    [ "$status" -eq 5 ]
    [ "$(out_field '.status')" = "parse_error" ]
}

@test "add: PSK with trailing LF rejected at jq layer" {
    # Without the jq gate this would slip past validators because bash $()
    # strips trailing newlines from command substitution output.
    run_apl_wifi add '{"ssid":"HomeNet","psk":"hunter22\n","test":false}'
    [ "$status" -eq 5 ]
    [ "$(out_field '.status')" = "parse_error" ]
}

@test "add: SSID with NUL byte rejected at jq layer" {
    # NUL bytes are dropped silently by bash command substitution; the jq
    # gate sees the raw JSON-escaped \u0000 and rejects.
    run_apl_wifi add '{"ssid":"home\u0000net","psk":"hunter22","test":false}'
    [ "$status" -eq 5 ]
    [ "$(out_field '.status')" = "parse_error" ]
}

@test "add: unknown field rejected as parse_error" {
    run_apl_wifi add '{"ssid":"HomeNet","psk":"hunter22","extra":"nope"}'
    [ "$status" -eq 5 ]
    [ "$(out_field '.status')" = "parse_error" ]
}

@test "add: non-object body rejected as parse_error" {
    run_apl_wifi add '"not an object"'
    [ "$status" -eq 5 ]
    [ "$(out_field '.status')" = "parse_error" ]
}

@test "add: slug collision adds -2 suffix" {
    # Seed an existing managed keyfile that would clash.
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-homenet.nmconnection" <<EOF
[connection]
id=existing
uuid=99999999-9999-4999-8999-999999999999
type=wifi

[wifi]
ssid=Existing
EOF
    run_apl_wifi add '{"ssid":"HomeNet","psk":"hunter22","test":false}'
    [ "$status" -eq 0 ]
    [ "$(out_field '.id')" = "airplanes-wifi-homenet-2" ]
}

# ---- update ---------------------------------------------------------------

@test "update: preserves UUID, rewrites SSID + PSK" {
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-old.nmconnection" <<EOF
[connection]
id=old
uuid=dddddddd-dddd-4ddd-8ddd-dddddddddddd
type=wifi

[wifi]
ssid=OldSSID

[wifi-security]
key-mgmt=wpa-psk
psk=oldpsk22
EOF
    run_apl_wifi update '{"id":"airplanes-wifi-old","ssid":"NewSSID","psk":"newpsk22","test":false}'
    [ "$status" -eq 0 ]
    [ "$(out_field '.status')" = "applied" ]
    [ "$(out_field '.uuid')" = "dddddddd-dddd-4ddd-8ddd-dddddddddddd" ]
    grep -q '^ssid=NewSSID$' "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-old.nmconnection"
    grep -q '^psk=newpsk22$' "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-old.nmconnection"
}

@test "update: omitted psk leaves existing psk untouched" {
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-old.nmconnection" <<EOF
[connection]
id=old
uuid=dddddddd-dddd-4ddd-8ddd-dddddddddddd
type=wifi

[wifi]
ssid=OldSSID

[wifi-security]
key-mgmt=wpa-psk
psk=keepme22
EOF
    run_apl_wifi update '{"id":"airplanes-wifi-old","priority":3,"test":false}'
    [ "$status" -eq 0 ]
    grep -q '^psk=keepme22$' "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-old.nmconnection"
    grep -q '^autoconnect-priority=3$' "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-old.nmconnection"
}

@test "update: explicit empty psk converts to open network" {
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-old.nmconnection" <<EOF
[connection]
id=old
uuid=dddddddd-dddd-4ddd-8ddd-dddddddddddd
type=wifi

[wifi]
ssid=OldSSID

[wifi-security]
key-mgmt=wpa-psk
psk=oldpsk22
EOF
    run_apl_wifi update '{"id":"airplanes-wifi-old","psk":"","test":false}'
    [ "$status" -eq 0 ]
    run grep -q '^\[wifi-security\]$' "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-old.nmconnection"
    [ "$status" -ne 0 ]
}

@test "update: unknown id rejected" {
    run_apl_wifi update '{"id":"airplanes-wifi-missing","ssid":"X","test":false}'
    [ "$status" -eq 2 ]
    [ "$(out_field '.status')" = "rejected" ]
    [ "$(out_field '.reason')" = "unknown_id" ]
}

@test "update: unmanaged id rejected" {
    run_apl_wifi update '{"id":"foreign-net","ssid":"X","test":false}'
    [ "$status" -eq 2 ]
    [ "$(out_field '.status')" = "rejected" ]
    [ "$(out_field '.reason')" = "unmanaged_id" ]
}

# ---- delete ---------------------------------------------------------------

@test "delete: removes keyfile and reports applied" {
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-x.nmconnection" <<EOF
[connection]
id=x
uuid=eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee
type=wifi

[wifi]
ssid=X
EOF
    # Second keyfile so this isn't the "last" — exercises the non-force path.
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-y.nmconnection" <<EOF
[connection]
id=y
uuid=ffffffff-ffff-4fff-8fff-ffffffffffff
type=wifi

[wifi]
ssid=Y
EOF
    run_apl_wifi delete '{"id":"airplanes-wifi-x"}'
    [ "$status" -eq 0 ]
    [ "$(out_field '.status')" = "applied" ]
    [ ! -f "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-x.nmconnection" ]
    [ -f "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-y.nmconnection" ]
}

@test "delete: last managed profile requires force_last" {
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-only.nmconnection" <<EOF
[connection]
id=only
uuid=11111111-1111-4111-8111-111111111111
type=wifi

[wifi]
ssid=OnlyNet
EOF
    run_apl_wifi delete '{"id":"airplanes-wifi-only"}'
    [ "$status" -eq 2 ]
    [ "$(out_field '.status')" = "rejected" ]
    [ "$(out_field '.reason')" = "requires_force_flag" ]
    [ "$(out_field '.missing[0]')" = "force_last" ]
    [ -f "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-only.nmconnection" ]
}

@test "delete: last managed profile + force_last succeeds" {
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-only.nmconnection" <<EOF
[connection]
id=only
uuid=11111111-1111-4111-8111-111111111111
type=wifi

[wifi]
ssid=OnlyNet
EOF
    run_apl_wifi delete '{"id":"airplanes-wifi-only","force_last":true}'
    [ "$status" -eq 0 ]
    [ "$(out_field '.status')" = "applied" ]
    [ ! -f "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-only.nmconnection" ]
}

@test "delete: active-connection-no-uplink requires force_active_no_uplink" {
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-x.nmconnection" <<EOF
[connection]
id=x
uuid=22222222-2222-4222-8222-222222222222
type=wifi

[wifi]
ssid=X
EOF
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-y.nmconnection" <<EOF
[connection]
id=y
uuid=33333333-3333-4333-8333-333333333333
type=wifi

[wifi]
ssid=Y
EOF
    export NMCLI_STUB_ACTIVE='22222222-2222-4222-8222-222222222222:802-11-wireless:wlan0'
    run_apl_wifi delete '{"id":"airplanes-wifi-x"}'
    [ "$status" -eq 2 ]
    [ "$(out_field '.reason')" = "requires_force_flag" ]
    [ "$(out_field '.missing[0]')" = "force_active_no_uplink" ]
}

@test "delete: active connection + loopback only → still requires force" {
    # Loopback appears in `connection show --active` on real NM installs but
    # is not an independent uplink. The fix filters to physical types only;
    # without it, a `lo` activation would silently suppress the strong-confirm.
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-x.nmconnection" <<EOF
[connection]
id=x
uuid=22222222-2222-4222-8222-222222222222
type=wifi

[wifi]
ssid=X
EOF
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-y.nmconnection" <<EOF
[connection]
id=y
uuid=33333333-3333-4333-8333-333333333333
type=wifi

[wifi]
ssid=Y
EOF
    export NMCLI_STUB_ACTIVE='22222222-2222-4222-8222-222222222222:802-11-wireless:wlan0
55555555-5555-4555-8555-555555555555:loopback:lo'
    run_apl_wifi delete '{"id":"airplanes-wifi-x"}'
    [ "$status" -eq 2 ]
    [ "$(out_field '.reason')" = "requires_force_flag" ]
    [ "$(out_field '.missing[0]')" = "force_active_no_uplink" ]
}

@test "delete: active connection + vpn only → still requires force" {
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-x.nmconnection" <<EOF
[connection]
id=x
uuid=22222222-2222-4222-8222-222222222222
type=wifi

[wifi]
ssid=X
EOF
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-y.nmconnection" <<EOF
[connection]
id=y
uuid=33333333-3333-4333-8333-333333333333
type=wifi

[wifi]
ssid=Y
EOF
    export NMCLI_STUB_ACTIVE='22222222-2222-4222-8222-222222222222:802-11-wireless:wlan0
66666666-6666-4666-8666-666666666666:wireguard:wg0'
    run_apl_wifi delete '{"id":"airplanes-wifi-x"}'
    [ "$status" -eq 2 ]
    [ "$(out_field '.missing[0]')" = "force_active_no_uplink" ]
}

@test "delete: invalid id (path traversal attempt) rejected" {
    # Regex gate rejects anything outside the canonical id shape. With the
    # prefix-only gate this would have reached apl_wifi_keyfile_path with
    # the `..` sequence and tried to access an unintended path.
    run_apl_wifi delete '{"id":"airplanes-wifi-../etc/passwd"}'
    [ "$status" -eq 2 ]
    [ "$(out_field '.status')" = "rejected" ]
    [ "$(out_field '.reason')" = "unmanaged_id" ]
}

@test "delete: active connection but ethernet up → no force needed" {
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-x.nmconnection" <<EOF
[connection]
id=x
uuid=22222222-2222-4222-8222-222222222222
type=wifi

[wifi]
ssid=X
EOF
    cat > "$APL_WIFI_KEYFILE_DIR/airplanes-wifi-y.nmconnection" <<EOF
[connection]
id=y
uuid=33333333-3333-4333-8333-333333333333
type=wifi

[wifi]
ssid=Y
EOF
    export NMCLI_STUB_ACTIVE='22222222-2222-4222-8222-222222222222:802-11-wireless:wlan0
44444444-4444-4444-8444-444444444444:802-3-ethernet:end0'
    run_apl_wifi delete '{"id":"airplanes-wifi-x"}'
    [ "$status" -eq 0 ]
    [ "$(out_field '.status')" = "applied" ]
}

@test "delete: unmanaged id rejected without filesystem mutation" {
    cat > "$APL_WIFI_KEYFILE_DIR/foreign-net.nmconnection" <<EOF
[connection]
id=foreign
uuid=ffffffff-eeee-4eee-8eee-eeeeeeeeeeee
type=wifi

[wifi]
ssid=Foreign
EOF
    run_apl_wifi delete '{"id":"foreign-net","force_last":true}'
    [ "$status" -eq 2 ]
    [ "$(out_field '.reason')" = "unmanaged_id" ]
    [ -f "$APL_WIFI_KEYFILE_DIR/foreign-net.nmconnection" ]
}

# ---- status ---------------------------------------------------------------

@test "status: no active connection → wifi_device disconnected" {
    run_apl_wifi status ""
    [ "$status" -eq 0 ]
    [ "$(out_field '.status')" = "ok" ]
    [ "$(out_field '.active_connection')" = "null" ]
    [ "$(out_field '.wifi_device.state')" = "disconnected" ]
    [ "$(out_field '.networkmanager_available')" = "true" ]
}

@test "status: surfaces ethernet uplink from nmcli" {
    export NMCLI_STUB_ACTIVE='44444444-4444-4444-8444-444444444444:802-3-ethernet:end0'
    export NMCLI_STUB_DEV_IP4='10.0.0.42/24'
    run_apl_wifi status ""
    [ "$status" -eq 0 ]
    [ "$(out_field '.non_wifi_uplinks | length')" = "1" ]
    [ "$(out_field '.non_wifi_uplinks[0].device')" = "end0" ]
    [ "$(out_field '.non_wifi_uplinks[0].ipv4')" = "10.0.0.42" ]
}

# ---- dispatcher / usage ---------------------------------------------------

@test "dispatcher: unknown subcommand → usage_error exit 5" {
    run_apl_wifi nope ""
    [ "$status" -eq 5 ]
    [ "$(out_field '.status')" = "usage_error" ]
}

@test "dispatcher: missing --json → usage_error" {
    run bash -c '"$0" list'  "$HELPER"
    [ "$status" -eq 5 ]
}

# ---- error envelope guarantee --------------------------------------------

@test "error trap: command failure produces valid JSON envelope" {
    # Force a hard error path: point UUID_SOURCE at a non-existent file and
    # invoke add (which needs to read it). The trap must still emit JSON.
    export APL_WIFI_UUID_SOURCE="$TMP/does-not-exist"
    run_apl_wifi add '{"ssid":"X","psk":"hunter22","test":false}'
    [ "$status" -ne 0 ]
    # Output must be parseable JSON with a "status" field.
    run jq -e '.status' <<<"$output"
    [ "$status" -eq 0 ]
}
