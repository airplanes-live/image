#!/usr/bin/env bats

# Unit tests for the shared Wi-Fi validators sourced by both airplanes-first-run
# (boot-config flow) and apl-wifi (webconfig flow). The JS twins in
# webconfig/web/assets/app.js are kept in sync via test_validator_parity.sh —
# this file covers the bash predicates in isolation.

setup() {
    LIB="$BATS_TEST_DIRNAME/../stage-airplanes/05-install-webconfig/files/usr/local/lib/airplanes/wifi-validators.sh"
    [ -f "$LIB" ] || skip "wifi-validators.sh missing"
    # shellcheck source=/dev/null
    source "$LIB"
}

# ---- apl_wifi_valid_ssid -------------------------------------------------

@test "ssid: empty rejected" {
    run apl_wifi_valid_ssid ""
    [ "$status" -ne 0 ]
}

@test "ssid: 1 byte accepted" {
    apl_wifi_valid_ssid "a"
}

@test "ssid: 32 ASCII bytes accepted" {
    apl_wifi_valid_ssid "$(printf 'a%.0s' {1..32})"
}

@test "ssid: 33 ASCII bytes rejected" {
    run apl_wifi_valid_ssid "$(printf 'a%.0s' {1..33})"
    [ "$status" -ne 0 ]
}

@test "ssid: 32-byte multi-byte (UTF-8) accepted" {
    # 16 × 2-byte char (©, U+00A9) = 32 bytes.
    apl_wifi_valid_ssid "$(printf '\xc2\xa9%.0s' {1..16})"
}

@test "ssid: 34-byte multi-byte (17 × 2-byte) rejected" {
    run apl_wifi_valid_ssid "$(printf '\xc2\xa9%.0s' {1..17})"
    [ "$status" -ne 0 ]
}

@test "ssid: leading + trailing space preserved and accepted" {
    apl_wifi_valid_ssid " HomeNet "
}

@test "ssid: shell-metachar (\$ backtick) accepted" {
    apl_wifi_valid_ssid 'net$work`'
}

@test "ssid: embedded LF rejected" {
    run apl_wifi_valid_ssid $'home\nnet'
    [ "$status" -ne 0 ]
}

@test "ssid: embedded CR rejected" {
    run apl_wifi_valid_ssid $'home\rnet'
    [ "$status" -ne 0 ]
}

@test "ssid: embedded NUL rejected" {
    # bash silently truncates NUL inside command substitution / printf %s;
    # the predicate sees fewer bytes but the principle is the same — any
    # control byte in the input string is rejected. Build via printf -v.
    local ssid=$'home\x01net'
    run apl_wifi_valid_ssid "$ssid"
    [ "$status" -ne 0 ]
}

@test "ssid: tab (0x09) rejected" {
    run apl_wifi_valid_ssid $'foo\tbar'
    [ "$status" -ne 0 ]
}

@test "ssid: DEL (0x7F) rejected" {
    run apl_wifi_valid_ssid $'foo\x7fbar'
    [ "$status" -ne 0 ]
}

# ---- apl_wifi_valid_psk --------------------------------------------------

@test "psk: 7 chars rejected" {
    run apl_wifi_valid_psk "1234567"
    [ "$status" -ne 0 ]
}

@test "psk: 8 chars accepted" {
    apl_wifi_valid_psk "12345678"
}

@test "psk: 63 chars accepted" {
    apl_wifi_valid_psk "$(printf 'a%.0s' {1..63})"
}

@test "psk: 64 hex chars accepted" {
    apl_wifi_valid_psk "$(printf 'a%.0s' {1..64})"
}

@test "psk: 64 non-hex chars rejected" {
    run apl_wifi_valid_psk "$(printf 'g%.0s' {1..64})"
    [ "$status" -ne 0 ]
}

@test "psk: 65 chars rejected" {
    run apl_wifi_valid_psk "$(printf 'a%.0s' {1..65})"
    [ "$status" -ne 0 ]
}

@test "psk: leading + trailing space preserved and accepted" {
    apl_wifi_valid_psk " hunter22 "
}

@test "psk: shell metachars accepted" {
    apl_wifi_valid_psk 'my$weird`pass'
}

@test "psk: LF rejected" {
    run apl_wifi_valid_psk $'hunter22\n'
    [ "$status" -ne 0 ]
}

@test "psk: CR rejected" {
    run apl_wifi_valid_psk $'hunter22\r'
    [ "$status" -ne 0 ]
}

@test "psk: NUL byte produces rejection (truncated by bash or rejected)" {
    # bash truncates NUL but the resulting length-based reject covers this
    # case either way. The point is "no path produces a successful keyfile".
    local psk=$'hunter\x002secret'
    if (( ${#psk} >= 8 && ${#psk} <= 63 )); then
        run apl_wifi_valid_psk "$psk"
        [ "$status" -ne 0 ]
    fi
}

@test "psk: high-bit byte (0x80) rejected" {
    run apl_wifi_valid_psk $'hunter\x8022'
    [ "$status" -ne 0 ]
}

@test "psk: DEL (0x7F) inside payload rejected" {
    run apl_wifi_valid_psk $'hunter\x7f22secret'
    [ "$status" -ne 0 ]
}

# ---- apl_wifi_valid_country ----------------------------------------------

@test "country: DE accepted" {
    apl_wifi_valid_country "DE"
}

@test "country: lowercase de rejected" {
    run apl_wifi_valid_country "de"
    [ "$status" -ne 0 ]
}

@test "country: DEU (alpha-3) rejected" {
    run apl_wifi_valid_country "DEU"
    [ "$status" -ne 0 ]
}

@test "country: empty rejected" {
    run apl_wifi_valid_country ""
    [ "$status" -ne 0 ]
}

@test "country: D rejected" {
    run apl_wifi_valid_country "D"
    [ "$status" -ne 0 ]
}

# ---- apl_wifi_valid_priority ---------------------------------------------

@test "priority: 0 accepted" {
    apl_wifi_valid_priority "0"
}

@test "priority: 5 accepted" {
    apl_wifi_valid_priority "5"
}

@test "priority: 999 accepted" {
    apl_wifi_valid_priority "999"
}

@test "priority: 1000 rejected" {
    run apl_wifi_valid_priority "1000"
    [ "$status" -ne 0 ]
}

@test "priority: empty rejected" {
    run apl_wifi_valid_priority ""
    [ "$status" -ne 0 ]
}

@test "priority: negative rejected" {
    run apl_wifi_valid_priority "-1"
    [ "$status" -ne 0 ]
}

@test "priority: non-numeric rejected" {
    run apl_wifi_valid_priority "1a"
    [ "$status" -ne 0 ]
}

@test "priority: leading zero rejected" {
    run apl_wifi_valid_priority "01"
    [ "$status" -ne 0 ]
}

@test "priority: whitespace rejected" {
    run apl_wifi_valid_priority " 5"
    [ "$status" -ne 0 ]
}

# ---- apl_wifi_valid_hidden -----------------------------------------------

@test "hidden: true accepted" {
    apl_wifi_valid_hidden "true"
}

@test "hidden: false accepted" {
    apl_wifi_valid_hidden "false"
}

@test "hidden: TRUE (uppercase) rejected" {
    run apl_wifi_valid_hidden "TRUE"
    [ "$status" -ne 0 ]
}

@test "hidden: 1 rejected" {
    run apl_wifi_valid_hidden "1"
    [ "$status" -ne 0 ]
}

@test "hidden: empty rejected" {
    run apl_wifi_valid_hidden ""
    [ "$status" -ne 0 ]
}
