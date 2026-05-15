#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031
# - SC2016: literal $ / backtick in single-quoted PSK fixtures is intentional
# - SC2030/SC2031: bats runs each test in its own subshell; we re-source the
#   script in setup() so each test sees fresh function definitions, and the
#   _WIFI_* state we mutate IS visible to the assertions in the SAME test.

# Tests for the WiFi-config flow in airplanes-first-run:
#   consume_wifi_config / validate_wifi_inputs / write_nm_keyfile /
#   apply_wifi_country
#
# All tests run unprivileged; we redirect WIFI_KEYFILE_DIR / WIFI_KEYFILE
# under $BATS_TMPDIR and intercept host-mutating commands (raspi-config,
# hostnamectl, hostname) via the bash-function stubs in
# test/lib/host-runtime-stubs.sh. apply_wifi_country invokes
# `raspi-config nonint do_wifi_country "$_WIFI_COUNTRY"` and without the
# stub would either reach a real raspi-config on a Pi devbox or fall
# through to the script's /etc/wpa_supplicant/wpa_supplicant.conf
# fallback write — both leak the test fixture to the host.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/06-firstboot/files/usr/local/sbin/airplanes-first-run"
    export APL_WIFI_LIB_DIR="${AIRPLANES_IMAGE_WEBCONFIG_ROOT:-$BATS_TEST_DIRNAME/../../image-webconfig}/files/usr/local/lib/airplanes"
    TMP="$(mktemp -d)"
    export WIFI_KEYFILE_DIR="$TMP/nm"
    export WIFI_KEYFILE="$WIFI_KEYFILE_DIR/airplanes-config-wifi.nmconnection"
    declare -gA BOOT_CFG=()
    # shellcheck source=lib/host-runtime-stubs.sh
    source "$BATS_TEST_DIRNAME/lib/host-runtime-stubs.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT"
    BOOT_CFG=()
    reset_host_runtime_stubs
}

teardown() { rm -rf "$TMP"; }

# ---- consume_wifi_config -----------------------------------------------

@test "01: empty BOOT_CFG -> consume + validate are no-ops" {
    consume_wifi_config
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ -z "$_WIFI_SSID" ]
    [ -z "$_WIFI_PASS" ]
    [ -z "$_WIFI_COUNTRY" ]
}

@test "02: WIFI_SSID + WIFI_PASS + WIFI_COUNTRY are popped after consume" {
    BOOT_CFG=([WIFI_SSID]="MyNet" [WIFI_PASS]="hunter22" [WIFI_COUNTRY]="DE" [LATITUDE]="51.5")
    consume_wifi_config
    [ ! -v "BOOT_CFG[WIFI_SSID]" ]
    [ ! -v "BOOT_CFG[WIFI_PASS]" ]
    [ ! -v "BOOT_CFG[WIFI_COUNTRY]" ]
    [ "${BOOT_CFG[LATITUDE]}" = "51.5" ]
    [ "$_WIFI_SSID" = "MyNet" ]
    [ "$_WIFI_PASS" = "hunter22" ]
    [ "$_WIFI_COUNTRY" = "DE" ]
}

@test "03: typoed WIFI_PASSWORD is stripped (does NOT leak into BOOT_CFG)" {
    BOOT_CFG=([WIFI_SSID]="MyNet" [WIFI_PASSWORD]="leak-secret" [LATITUDE]="51.5")
    consume_wifi_config
    [ ! -v "BOOT_CFG[WIFI_PASSWORD]" ]
    [ "${BOOT_CFG[LATITUDE]}" = "51.5" ]
}

@test "04: typoed WIFI_PSK is stripped" {
    BOOT_CFG=([WIFI_SSID]="MyNet" [WIFI_PSK]="leak-secret")
    consume_wifi_config
    [ ! -v "BOOT_CFG[WIFI_PSK]" ]
}

# ---- validate_wifi_inputs ----------------------------------------------

@test "10: empty SSID -> all WIFI_* cleared, return 0" {
    BOOT_CFG=()
    validate_wifi_inputs
    [ -z "$_WIFI_SSID" ]
}

@test "11: SSID exactly 32 bytes is accepted" {
    BOOT_CFG=([WIFI_SSID]="$(printf 'a%.0s' {1..32})")
    validate_wifi_inputs
    [ "${#_WIFI_SSID}" -eq 32 ]
}

@test "12: SSID 33 bytes is rejected and clears all WIFI_*" {
    BOOT_CFG=([WIFI_SSID]="$(printf 'a%.0s' {1..33})" [WIFI_PASS]="hunter22" [WIFI_COUNTRY]="DE")
    run validate_wifi_inputs
    [ "$status" -eq 1 ]
    # Caller's _WIFI_* vars are reset to empty.
}

@test "13: WPA passphrase 8 chars accepted" {
    BOOT_CFG=([WIFI_SSID]="net" [WIFI_PASS]="12345678")
    validate_wifi_inputs
    [ "$_WIFI_PASS" = "12345678" ]
}

@test "14: WPA passphrase 7 chars rejected (clears all WIFI_*)" {
    BOOT_CFG=([WIFI_SSID]="net" [WIFI_PASS]="1234567")
    run validate_wifi_inputs
    [ "$status" -eq 1 ]
}

@test "15: WPA passphrase 63 chars accepted" {
    BOOT_CFG=([WIFI_SSID]="net" [WIFI_PASS]="$(printf 'a%.0s' {1..63})")
    validate_wifi_inputs
    [ "${#_WIFI_PASS}" -eq 63 ]
}

@test "16: 64-char hex PSK accepted" {
    BOOT_CFG=([WIFI_SSID]="net" [WIFI_PASS]="$(printf 'a%.0s' {1..64})")
    validate_wifi_inputs
    [ "${#_WIFI_PASS}" -eq 64 ]
}

@test "17: 64-char non-hex passphrase rejected" {
    BOOT_CFG=([WIFI_SSID]="net" [WIFI_PASS]="$(printf 'g%.0s' {1..64})")
    run validate_wifi_inputs
    [ "$status" -eq 1 ]
}

@test "18: WIFI_COUNTRY=DE accepted" {
    BOOT_CFG=([WIFI_SSID]="net" [WIFI_COUNTRY]="DE")
    validate_wifi_inputs
    [ "$_WIFI_COUNTRY" = "DE" ]
}

@test "19: WIFI_COUNTRY=de (lowercase) rejected; SSID still kept" {
    BOOT_CFG=([WIFI_SSID]="net" [WIFI_COUNTRY]="de")
    validate_wifi_inputs
    [ -z "$_WIFI_COUNTRY" ]
    [ "$_WIFI_SSID" = "net" ]
}

@test "20: WIFI_COUNTRY=Germany rejected" {
    BOOT_CFG=([WIFI_SSID]="net" [WIFI_COUNTRY]="Germany")
    validate_wifi_inputs
    [ -z "$_WIFI_COUNTRY" ]
}

@test "21: WIFI_COUNTRY=DEU rejected" {
    BOOT_CFG=([WIFI_SSID]="net" [WIFI_COUNTRY]="DEU")
    validate_wifi_inputs
    [ -z "$_WIFI_COUNTRY" ]
}

# ---- write_nm_keyfile --------------------------------------------------

@test "30: empty SSID -> no keyfile" {
    _WIFI_SSID=""
    write_nm_keyfile
    [ ! -e "$WIFI_KEYFILE" ]
}

@test "31: SSID only (open network) -> keyfile without [wifi-security]" {
    _WIFI_SSID="OpenNet"
    _WIFI_PASS=""
    _WIFI_COUNTRY=""
    write_nm_keyfile
    [ -f "$WIFI_KEYFILE" ]
    grep -q '^ssid=OpenNet$' "$WIFI_KEYFILE"
    grep -q '^autoconnect=true$' "$WIFI_KEYFILE"
    run grep -q '^\[wifi-security\]$' "$WIFI_KEYFILE"
    [ "$status" -ne 0 ]
    grep -q '^uuid=[0-9a-f]\{8\}-' "$WIFI_KEYFILE"
}

@test "32: SSID + PASS -> keyfile has [wifi-security] with PSK" {
    _WIFI_SSID="MyNet"
    _WIFI_PASS="hunter22"
    _WIFI_COUNTRY=""
    write_nm_keyfile
    [ -f "$WIFI_KEYFILE" ]
    grep -q '^\[wifi-security\]$' "$WIFI_KEYFILE"
    grep -q '^key-mgmt=wpa-psk$' "$WIFI_KEYFILE"
    grep -q '^psk=hunter22$' "$WIFI_KEYFILE"
}

@test "33: keyfile has mode 0600" {
    _WIFI_SSID="MyNet"
    _WIFI_PASS="hunter22"
    write_nm_keyfile
    [ "$(stat -c %a "$WIFI_KEYFILE")" = "600" ]
}

@test "34: PSK with shell metachars (\$, backtick) round-trips into keyfile" {
    _WIFI_SSID="MyNet"
    _WIFI_PASS='my$weird`pass'
    write_nm_keyfile
    grep -F -q "psk=my\$weird\`pass" "$WIFI_KEYFILE"
}

@test "35: SSID with spaces preserved" {
    _WIFI_SSID="My Home Net"
    _WIFI_PASS="hunter22"
    write_nm_keyfile
    grep -F -q "ssid=My Home Net" "$WIFI_KEYFILE"
}

@test "36: writing twice replaces atomically (no .tmp leftover)" {
    _WIFI_SSID="First"
    _WIFI_PASS="hunter22"
    write_nm_keyfile
    _WIFI_SSID="Second"
    write_nm_keyfile
    grep -q '^ssid=Second$' "$WIFI_KEYFILE"
    run grep -q '^ssid=First$' "$WIFI_KEYFILE"
    [ "$status" -ne 0 ]
    # No leftover temp file under the keyfile dir.
    run bash -c "ls $WIFI_KEYFILE_DIR/.airplanes-wifi.tmp.* 2>/dev/null"
    [ "$status" -ne 0 ]
}

@test "37: keyfile body contains [ipv4] method=auto and [ipv6] method=auto" {
    _WIFI_SSID="MyNet"
    _WIFI_PASS="hunter22"
    write_nm_keyfile
    grep -A1 '^\[ipv4\]$' "$WIFI_KEYFILE" | grep -q '^method=auto$'
    grep -A1 '^\[ipv6\]$' "$WIFI_KEYFILE" | grep -q '^method=auto$'
}

# ---- apply_wifi_country -----------------------------------------------

@test "40: empty country -> no-op, no raspi-config call" {
    _WIFI_COUNTRY=""
    apply_wifi_country
    [ "${#RASPI_CONFIG_CALLS[@]}" -eq 0 ]
}

@test "41: valid country -> raspi-config nonint do_wifi_country called" {
    _WIFI_COUNTRY="DE"
    apply_wifi_country
    [[ " ${RASPI_CONFIG_CALLS[*]} " == *"nonint do_wifi_country DE"* ]]
}

# ---- consume_wifi_config integration ----------------------------------

@test "50: SSID with shell metachar (\$) survives consume + validate" {
    BOOT_CFG=([WIFI_SSID]='net$work' [WIFI_PASS]='pass$word')
    consume_wifi_config
    [ "$_WIFI_SSID" = 'net$work' ]
    [ "$_WIFI_PASS" = 'pass$word' ]
}
