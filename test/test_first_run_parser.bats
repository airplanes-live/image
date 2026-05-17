#!/usr/bin/env bats

# Sources airplanes-first-run for direct access to parse_boot_config /
# merge_feed_env / reject_unknown_boot_key. The BASH_SOURCE guard at the
# bottom of the script suppresses main() execution on source. Each bats test
# runs in its own process, so BOOT_CFG state does not leak between tests.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/06-firstboot/files/usr/local/sbin/airplanes-first-run"
    export APL_WIFI_LIB_DIR="${AIRPLANES_IMAGE_WEBCONFIG_ROOT:-$BATS_TEST_DIRNAME/../../image-webconfig}/files/usr/local/lib/airplanes"
    TEMPLATE="$BATS_TEST_DIRNAME/../stage-airplanes/06-firstboot/files/boot/firmware/airplanes-config.txt"
    TMP="$(mktemp -d)"
    FIXTURE="$TMP/cfg.txt"
    # shellcheck source=/dev/null
    source "$SCRIPT"
}

teardown() { rm -rf "$TMP"; }

# ---- empty / comment-only files --------------------------------------------

@test "01: empty file -> empty BOOT_CFG" {
    : > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
}

@test "02: only comments + blank lines -> empty" {
    cat > "$FIXTURE" <<'EOF'
# a comment

  # indented comment

EOF
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
}

@test "03: tab/space-prefixed comment is ignored" {
    printf '\t# tabbed comment\n   # spaced comment\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

# ---- allowlisted-key parsing (parser shape, key-agnostic) -------------------
# These cover the parser's structural behavior — quoting, BOM, CRLF, whitespace
# trim/preserve, reentrancy. Fixture keys are FEED_HOST / HOSTNAME because
# those are the non-WIFI allowlisted keys (WIFI_* values bypass the
# shell-metachar reject, which we want to keep firing here).

@test "10: HOSTNAME=airplanes-feeder (unquoted) is captured" {
    echo "HOSTNAME=airplanes-feeder" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[HOSTNAME]}" = "airplanes-feeder" ]
    [ "${#BOOT_CFG[@]}" -eq 1 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
}

@test "11: FEED_HOST=\"mybackend.local\" strips surrounding quotes" {
    echo 'FEED_HOST="mybackend.local"' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[FEED_HOST]}" = "mybackend.local" ]
}

@test "12: HOSTNAME= (empty value) is treated as unset" {
    echo "HOSTNAME=" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "13: FEED_HOST=\"\" (empty quoted) is treated as unset" {
    echo 'FEED_HOST=""' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "14: UTF-8 BOM on first line is stripped" {
    printf '\xef\xbb\xbfHOSTNAME=feeder1\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[HOSTNAME]}" = "feeder1" ]
}

@test "15: CRLF line endings are tolerated" {
    printf 'HOSTNAME=feeder1\r\nFEED_HOST=test.local\r\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[HOSTNAME]}" = "feeder1" ]
    [ "${BOOT_CFG[FEED_HOST]}" = "test.local" ]
}

@test "16: leading whitespace before key is tolerated" {
    printf '   HOSTNAME=feeder1\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[HOSTNAME]}" = "feeder1" ]
}

@test "17: unquoted value with trailing space is trimmed" {
    printf 'HOSTNAME=feeder1 \n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[HOSTNAME]}" = "feeder1" ]
}

@test "18: unquoted value with surrounding whitespace is trimmed" {
    printf 'HOSTNAME=  feeder1  \n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[HOSTNAME]}" = "feeder1" ]
}

@test "19: quoted value with trailing space preserves whitespace verbatim" {
    # Quoted values express explicit intent — do NOT trim.
    echo 'HOSTNAME="feeder1 "' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[HOSTNAME]}" = "feeder1 " ]
}

@test "20: line missing = is recorded as malformed" {
    echo "HOSTNAME feeder1" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 1 ]
    [[ "${BOOT_CFG_ERRORS[0]}" =~ malformed ]]
}

@test "21: line starting with = (no key) is recorded as malformed" {
    echo "=value" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    # Doesn't match the KEY=value regex at all — falls through to the
    # malformed-line branch.
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 1 ]
    [[ "${BOOT_CFG_ERRORS[0]}" =~ malformed ]]
}

@test "22: key starting with digit is recorded as malformed" {
    echo "123KEY=value" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 1 ]
    [[ "${BOOT_CFG_ERRORS[0]}" =~ malformed ]]
}

@test "23: reentrancy — second parse clears state from first" {
    echo "HOSTNAME=feeder1" > "$TMP/A.txt"
    echo "FEED_HOST=test.local" > "$TMP/B.txt"
    parse_boot_config "$TMP/A.txt"
    [ "${BOOT_CFG[HOSTNAME]}" = "feeder1" ]
    parse_boot_config "$TMP/B.txt"
    [ "${BOOT_CFG[FEED_HOST]}" = "test.local" ]
    [ -z "${BOOT_CFG[HOSTNAME]+set}" ]
    [ "${#BOOT_CFG[@]}" -eq 1 ]
}

@test "24: multiple allowlisted keys in one file all propagate" {
    cat > "$FIXTURE" <<'EOF'
HOSTNAME=feeder1
FEED_HOST=mybackend.local
WIFI_SSID="My Net"
WIFI_PASS="hunter2-secret"
WIFI_COUNTRY=DE
EOF
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[HOSTNAME]}" = "feeder1" ]
    [ "${BOOT_CFG[FEED_HOST]}" = "mybackend.local" ]
    [ "${BOOT_CFG[WIFI_SSID]}" = "My Net" ]
    [ "${BOOT_CFG[WIFI_PASS]}" = "hunter2-secret" ]
    [ "${BOOT_CFG[WIFI_COUNTRY]}" = "DE" ]
    [ "${#BOOT_CFG[@]}" -eq 5 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
}

# ---- allowlist rejection (3 categories) ------------------------------------

@test "30: LATITUDE rejected with 'webconfig UI' message (webconfig-writable)" {
    echo "LATITUDE=51.5" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 1 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"LATITUDE"* ]]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"webconfig UI"* ]]
}

@test "31: each webconfig-writable key gets the 'webconfig UI' message" {
    cat > "$FIXTURE" <<'EOF'
LATITUDE=51.5
LONGITUDE=-0.1
ALTITUDE=20m
MLAT_USER=test-feeder
MLAT_ENABLED=true
GAIN=auto
UAT_INPUT=127.0.0.1:30978
EOF
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 7 ]
    local err
    for err in "${BOOT_CFG_ERRORS[@]}"; do
        [[ "$err" == *"webconfig UI"* ]] || { echo "missing 'webconfig UI' in: $err"; return 1; }
    done
}

@test "32: feed.env-only keys get the 'edit feed.env' message" {
    cat > "$FIXTURE" <<'EOF'
MLATSERVER=lab:31090
TARGET=--net-connector lab,30004,beast_reduce_plus_out
INPUT=127.0.0.1:30005
INPUT_TYPE=beast
READSB_SDR_SERIAL=00001090
DUMP978_SDR_SERIAL=00000978
DUMP978_GAIN=42.1
EOF
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 7 ]
    local err
    for err in "${BOOT_CFG_ERRORS[@]}"; do
        [[ "$err" == *"feed.env"* ]] || { echo "missing 'feed.env' in: $err"; return 1; }
    done
}

@test "33: legacy USER and DUMP978 also fall under the 'edit feed.env' message" {
    cat > "$FIXTURE" <<'EOF'
USER=alice
DUMP978=yes
EOF
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 2 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"feed.env"* ]]
    [[ "${BOOT_CFG_ERRORS[1]}" == *"feed.env"* ]]
}

@test "34: WIFI_PASSWORD typo rejected with WiFi-specific guidance (no value echoed)" {
    # WIFI_PASSWORD is the most likely typo and the most dangerous to leak.
    # Error must name WIFI_PASSWORD, point at WIFI_SSID/WIFI_PASS/WIFI_COUNTRY,
    # and NEVER echo the value.
    echo 'WIFI_PASSWORD="hunter22-secret"' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 1 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"WIFI_PASSWORD"* ]]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"WIFI_SSID"* ]]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"WIFI_PASS"* ]]
    [[ "${BOOT_CFG_ERRORS[0]}" != *"hunter22"* ]]
}

@test "35: random unknown key falls under the 'edit feed.env' message" {
    echo "MY_CUSTOM_KEY=value" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 1 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"MY_CUSTOM_KEY"* ]]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"feed.env"* ]]
}

# ---- allowlist ordering: fires before empty-value and shell-metachar ------
# The check fires at parse time, before the quote strip, empty-value skip,
# and shell-metachar reject — so the user gets the category-specific error
# rather than a less helpful "silently dropped" or "unsafe value" response.

@test "40: 'UAT_INPUT=' (empty value) lands the webconfig error, not silent drop" {
    echo "UAT_INPUT=" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 1 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"UAT_INPUT"* ]]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"webconfig UI"* ]]
}

@test "41: 'LATITUDE=\$(rm -rf /)' lands the webconfig error, not 'unsafe value'" {
    printf 'LATITUDE=$(rm -rf /)\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 1 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"LATITUDE"* ]]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"webconfig UI"* ]]
    [[ "${BOOT_CFG_ERRORS[0]}" != *"unsafe value"* ]]
}

@test "42: 'USER=\`whoami\`' lands the feed.env error, not 'unsafe value'" {
    printf 'USER=`whoami`\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 1 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"USER"* ]]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"feed.env"* ]]
    [[ "${BOOT_CFG_ERRORS[0]}" != *"unsafe value"* ]]
}

# ---- shell-metachar reject still fires for allowlisted non-WIFI keys -------
# The metachar reject is defense-in-depth for HOSTNAME and FEED_HOST values,
# which DO land in feed.env (FEED_HOST via MLATSERVER/TARGET synthesis;
# HOSTNAME via /etc/hostname). WIFI_* values go to an NM keyfile that's not
# shell-sourced, so they're exempt.

@test "50: HOSTNAME=\$(...) rejected as unsafe value" {
    printf 'HOSTNAME=$(rm -rf /)\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"unsafe value"* ]]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"HOSTNAME"* ]]
}

@test "51: HOSTNAME with backtick rejected as unsafe value" {
    printf 'HOSTNAME=`whoami`\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"unsafe value"* ]]
}

@test "52: HOSTNAME with embedded double-quote rejected" {
    printf 'HOSTNAME=foo"bar\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"unsafe value"* ]]
}

@test "53: HOSTNAME with embedded backslash rejected" {
    printf 'HOSTNAME=foo\\bar\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"unsafe value"* ]]
}

@test "54: FEED_HOST with embedded \$ rejected (defense in depth past expand_feed_host)" {
    # expand_feed_host has its own regex that rejects shell metachars, but the
    # parse-time reject is the first line of defense.
    printf 'FEED_HOST=foo$bar\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"unsafe value"* ]]
}

# ---- WIFI_* metachar exemption ---------------------------------------------
# WIFI_* values are written to an NM keyfile (line-based, not eval'd), so
# common password chars like $, \, and backtick must survive the parser.

@test "60: WIFI_PASS with \$ is preserved (NM keyfile is not eval'd)" {
    echo 'WIFI_PASS="my$pass"' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[WIFI_PASS]}" = 'my$pass' ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
}

@test "61: WIFI_PASS with backslash is preserved" {
    echo 'WIFI_PASS="my\\pass"' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[WIFI_PASS]}" = 'my\\pass' ]
}

@test "62: WIFI_PASS with backtick is preserved" {
    echo 'WIFI_PASS="back`tick"' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[WIFI_PASS]}" = 'back`tick' ]
}

@test "63: WIFI_SSID with \$ is preserved" {
    echo 'WIFI_SSID="net$work"' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[WIFI_SSID]}" = 'net$work' ]
}

@test "64: WIFI_COUNTRY=DE parses (validation happens at consume_wifi_config)" {
    echo "WIFI_COUNTRY=DE" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[WIFI_COUNTRY]}" = "DE" ]
}

# ---- template alignment ----------------------------------------------------

@test "70: shipped airplanes-config.txt template parses to empty BOOT_CFG (all keys commented)" {
    # Alignment guard: all five allowlisted keys ship commented out in the
    # template. The image's operational defaults come from feed/configure.sh
    # during chroot install, not the boot template; the template is the
    # *override* surface, not the default surface.
    parse_boot_config "$TEMPLATE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
}

# ---- merge round-trip ------------------------------------------------------

@test "80: merge_feed_env output round-trips through 'source' safely" {
    FEED_ENV="$TMP/feed.env"
    LOCK_FILE="$TMP/lock"
    : > "$FEED_ENV"
    BOOT_CFG=([MLATSERVER]='test.local:31090' [TARGET]='--net-connector test.local,30004,beast_reduce_plus_out')
    merge_feed_env
    set -a
    # shellcheck source=/dev/null
    source "$FEED_ENV"
    set +a
    [ "$MLATSERVER" = "test.local:31090" ]
    [ "$TARGET" = "--net-connector test.local,30004,beast_reduce_plus_out" ]
}

# ---- WEBSITE_URL parser capture --------------------------------------------

@test "100: WEBSITE_URL=https://homelab.airplanes.test captured" {
    echo "WEBSITE_URL=https://homelab.airplanes.test" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[WEBSITE_URL]}" = "https://homelab.airplanes.test" ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
}

@test "101: WEBSITE_URL=\"http://host:8080/api\" strips surrounding quotes" {
    echo 'WEBSITE_URL="http://host:8080/api"' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[WEBSITE_URL]}" = "http://host:8080/api" ]
}

# ---- _website_url_is_valid -------------------------------------------------

@test "110: _website_url_is_valid: http://host accepts" {
    _website_url_is_valid "http://homelab.airplanes.test"
}

@test "111: _website_url_is_valid: https://host accepts" {
    _website_url_is_valid "https://homelab.airplanes.test"
}

@test "112: _website_url_is_valid: http://host:8080 accepts" {
    _website_url_is_valid "http://homelab.airplanes.test:8080"
}

@test "113: _website_url_is_valid: http://host/path accepts" {
    _website_url_is_valid "http://homelab.airplanes.test/api/v1"
}

@test "114: _website_url_is_valid: http://192.168.1.10:18080 accepts" {
    _website_url_is_valid "http://192.168.1.10:18080"
}

@test "115: _website_url_is_valid: single-label host accepts" {
    _website_url_is_valid "http://homelab"
}

@test "120: _website_url_is_valid: missing scheme rejected" {
    ! _website_url_is_valid "homelab.airplanes.test"
}

@test "121: _website_url_is_valid: ftp:// rejected" {
    ! _website_url_is_valid "ftp://homelab.airplanes.test"
}

@test "122: _website_url_is_valid: file:// rejected" {
    ! _website_url_is_valid "file:///etc/passwd"
}

@test "123: _website_url_is_valid: userinfo rejected" {
    ! _website_url_is_valid "http://user:pass@homelab.airplanes.test"
}

@test "124: _website_url_is_valid: query string rejected" {
    ! _website_url_is_valid "http://homelab.airplanes.test/?foo=bar"
}

@test "125: _website_url_is_valid: fragment rejected" {
    ! _website_url_is_valid "http://homelab.airplanes.test/api#top"
}

@test "126: _website_url_is_valid: port 0 rejected" {
    ! _website_url_is_valid "http://homelab:0"
}

@test "127: _website_url_is_valid: port 65536 rejected" {
    ! _website_url_is_valid "http://homelab:65536"
}

@test "128: _website_url_is_valid: invalid IPv4 octet rejected" {
    ! _website_url_is_valid "http://10.0.0.256"
}

@test "129: _website_url_is_valid: too-many IPv4 octets rejected" {
    ! _website_url_is_valid "http://1.2.3.4.5"
}

@test "130: _website_url_is_valid: empty after scheme rejected" {
    ! _website_url_is_valid "http://"
}

@test "131: _website_url_is_valid: space in host rejected" {
    ! _website_url_is_valid "http://bad host"
}

@test "132: _website_url_is_valid: shell metachar in path rejected" {
    ! _website_url_is_valid 'http://host/$(rm)'
}

# ---- expand_website_url ----------------------------------------------------

@test "140: expand_website_url: writes APL_FEED_WEBSITE_URL, strips source key" {
    BOOT_CFG=([WEBSITE_URL]="http://homelab.airplanes.test")
    expand_website_url
    [ "${BOOT_CFG[APL_FEED_WEBSITE_URL]}" = "http://homelab.airplanes.test" ]
    [ -z "${BOOT_CFG[WEBSITE_URL]+set}" ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
}

@test "141: expand_website_url: trailing slash on bare authority normalised" {
    BOOT_CFG=([WEBSITE_URL]="http://homelab.airplanes.test/")
    expand_website_url
    [ "${BOOT_CFG[APL_FEED_WEBSITE_URL]}" = "http://homelab.airplanes.test" ]
}

@test "142: expand_website_url: invalid value records error and strips key" {
    BOOT_CFG=([WEBSITE_URL]="not-a-url")
    expand_website_url
    [ -z "${BOOT_CFG[APL_FEED_WEBSITE_URL]+set}" ]
    [ -z "${BOOT_CFG[WEBSITE_URL]+set}" ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 1 ]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"WEBSITE_URL"* ]]
    [[ "${BOOT_CFG_ERRORS[0]}" == *"invalid value"* ]]
}

@test "143: expand_website_url: unset key is a no-op" {
    BOOT_CFG=()
    expand_website_url
    [ "${#BOOT_CFG[@]}" -eq 0 ]
    [ "${#BOOT_CFG_ERRORS[@]}" -eq 0 ]
}

# ---- merge_feed_env: mode preservation -------------------------------------
# chown --reference needs root, so bats only validates the chmod side. The
# unit-file CI job (first-run-systemd) covers the chown half end-to-end.

@test "150: merge_feed_env preserves feed.env file mode across rewrite" {
    FEED_ENV="$TMP/feed.env"
    LOCK_FILE="$TMP/lock"
    : > "$FEED_ENV"
    chmod 0644 "$FEED_ENV"
    BOOT_CFG=([APL_FEED_WEBSITE_URL]="http://homelab.airplanes.test")
    merge_feed_env
    local mode
    mode="$(stat -c '%a' "$FEED_ENV")"
    [ "$mode" = "644" ]
    grep -q '^APL_FEED_WEBSITE_URL="http://homelab.airplanes.test"$' "$FEED_ENV"
}

@test "151: merge_feed_env: missing feed.env results in 0644 default" {
    FEED_ENV="$TMP/feed.env"
    LOCK_FILE="$TMP/lock"
    rm -f "$FEED_ENV"
    BOOT_CFG=([APL_FEED_WEBSITE_URL]="http://homelab.airplanes.test")
    merge_feed_env
    [ -f "$FEED_ENV" ]
    local mode
    mode="$(stat -c '%a' "$FEED_ENV")"
    [ "$mode" = "644" ]
}

# ---- retired-function regression guards ------------------------------------

@test "90: toggle_978_services is no longer defined" {
    ! type -t toggle_978_services >/dev/null 2>&1
}

@test "91: apply_dump978_to_uat_input is no longer defined" {
    ! type -t apply_dump978_to_uat_input >/dev/null 2>&1
}

@test "92: apply_user_to_mlat_split is no longer defined" {
    ! type -t apply_user_to_mlat_split >/dev/null 2>&1
}

@test "93: _feed_host_drop_lone_override is no longer defined" {
    ! type -t _feed_host_drop_lone_override >/dev/null 2>&1
}
