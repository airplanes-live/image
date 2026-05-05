#!/usr/bin/env bats

# Sources airplanes-first-run for direct access to parse_boot_config /
# merge_feed_env. The BASH_SOURCE guard at the bottom of the script suppresses
# main() execution on source. Each bats test runs in its own process, so
# BOOT_CFG state does not leak between tests.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/06-firstboot/files/usr/local/sbin/airplanes-first-run"
    TEMPLATE="$BATS_TEST_DIRNAME/../stage-airplanes/06-firstboot/files/boot/firmware/airplanes-config.txt"
    TMP="$(mktemp -d)"
    FIXTURE="$TMP/cfg.txt"
    # shellcheck source=/dev/null
    source "$SCRIPT"
}

teardown() { rm -rf "$TMP"; }

@test "01: empty file -> empty BOOT_CFG" {
    : > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "02: only comments + blank lines -> empty" {
    cat > "$FIXTURE" <<'EOF'
# a comment

  # indented comment

EOF
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "03: LATITUDE=51.5 (unquoted) is captured" {
    echo "LATITUDE=51.5" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[LATITUDE]}" = "51.5" ]
    [ "${#BOOT_CFG[@]}" -eq 1 ]
}

@test "04: LATITUDE=\"51.5\" strips surrounding quotes" {
    echo 'LATITUDE="51.5"' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[LATITUDE]}" = "51.5" ]
}

@test "05: LATITUDE= (empty value) is treated as unset" {
    echo "LATITUDE=" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "06: LATITUDE=\"\" (empty quoted) is treated as unset" {
    echo 'LATITUDE=""' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "07: sentinel LATITUDE=0 is filtered" {
    echo "LATITUDE=0" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "08: sentinel LONGITUDE=0 is filtered" {
    echo "LONGITUDE=0" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "09: sentinel ALTITUDE=0m is filtered" {
    echo "ALTITUDE=0m" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "10: USER has no sentinel — template default propagates" {
    # USER is intentionally not sentinel-gated. The template ships
    # `USER=airplanes-live-image` so unconfigured feeders show identifiably
    # on the MLAT map instead of taking feed.env's generic placeholder.
    echo "USER=airplanes-live-image" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[USER]}" = "airplanes-live-image" ]
    [ "${#BOOT_CFG[@]}" -eq 1 ]
}

@test "11: sentinel DUMP978=no is filtered" {
    echo "DUMP978=no" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "12: DUMP978=yes (real value, key has sentinel) propagates" {
    echo "DUMP978=yes" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[DUMP978]}" = "yes" ]
}

@test "13: LATITUDE=0.5 (close to sentinel 0 but distinct) propagates" {
    echo "LATITUDE=0.5" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[LATITUDE]}" = "0.5" ]
}

@test "14: LATITUDE=0.0 (numeric-equivalent zero) is treated as REAL value" {
    # User decision: literal-string sentinel match only. 0.0 is the equator,
    # a real coordinate distinct from the unconfigured sentinel "0".
    echo "LATITUDE=0.0" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[LATITUDE]}" = "0.0" ]
}

@test "15: UTF-8 BOM on first line is stripped" {
    printf '\xef\xbb\xbfLATITUDE=51.5\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[LATITUDE]}" = "51.5" ]
}

@test "16: CRLF line endings are tolerated" {
    printf 'LATITUDE=51.5\r\nLONGITUDE=-0.1\r\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[LATITUDE]}" = "51.5" ]
    [ "${BOOT_CFG[LONGITUDE]}" = "-0.1" ]
}

@test "17: leading whitespace before key is tolerated" {
    printf '   USER=foo\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[USER]}" = "foo" ]
}

@test "18: tab/space-prefixed comment is ignored" {
    printf '\t# tabbed comment\n   # spaced comment\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "19: trailing space on unquoted sentinel still matches sentinel after trim" {
    printf 'LATITUDE=0 \n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "20: surrounding whitespace on unquoted sentinel still matches" {
    printf 'LATITUDE=  0  \n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "21: quoted value with trailing space preserves whitespace verbatim" {
    # Quoted values express explicit intent — do NOT trim. Result is a real
    # value (not sentinel) because the literal "0 " != "0".
    echo 'LATITUDE="0 "' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[LATITUDE]}" = "0 " ]
}

@test "22: line missing = is silently skipped" {
    echo "LATITUDE 51.5" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "23: line starting with = (no key) is silently skipped" {
    echo "=value" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "24: key starting with digit is silently skipped" {
    echo "123KEY=value" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "25: mixed real + sentinel keeps only the real ones" {
    # LATITUDE=0 is sentinel-filtered; LONGITUDE=-0.1, USER (no sentinel),
    # and DUMP978=yes propagate.
    cat > "$FIXTURE" <<'EOF'
LATITUDE=0
LONGITUDE=-0.1
USER=airplanes-live-image
DUMP978=yes
EOF
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[LONGITUDE]}" = "-0.1" ]
    [ "${BOOT_CFG[USER]}" = "airplanes-live-image" ]
    [ "${BOOT_CFG[DUMP978]}" = "yes" ]
    [ "${#BOOT_CFG[@]}" -eq 3 ]
}

@test "26: shell-injection \$(...) is rejected" {
    printf 'USER=$(rm -rf /)\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE" 2>/dev/null
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "27: shell-injection backtick is rejected" {
    printf 'USER=`whoami`\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE" 2>/dev/null
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "28: shell-injection embedded double-quote is rejected" {
    printf 'USER=foo"bar\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE" 2>/dev/null
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "29: shell-injection embedded backslash is rejected" {
    printf 'USER=foo\\bar\n' > "$FIXTURE"
    parse_boot_config "$FIXTURE" 2>/dev/null
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "30: reentrancy — second parse clears state from first" {
    echo "LATITUDE=51.5" > "$TMP/A.txt"
    echo "USER=foo" > "$TMP/B.txt"
    parse_boot_config "$TMP/A.txt"
    [ "${BOOT_CFG[LATITUDE]}" = "51.5" ]
    parse_boot_config "$TMP/B.txt"
    [ "${BOOT_CFG[USER]}" = "foo" ]
    [ -z "${BOOT_CFG[LATITUDE]+set}" ]
    [ "${#BOOT_CFG[@]}" -eq 1 ]
}

@test "31: shipped airplanes-config.txt template parses to only the friendly USER default" {
    # Alignment guard: if anyone adds a non-sentinel default to the template
    # other than USER, OR drops USER from the template, OR re-adds USER as
    # a sentinel, this test fails. Sentinel-gated keys (LATITUDE, LONGITUDE,
    # ALTITUDE, DUMP978) must still parse to "not in BOOT_CFG"; USER alone
    # propagates the friendly default airplanes-live-image.
    parse_boot_config "$TEMPLATE"
    [ "${BOOT_CFG[USER]}" = "airplanes-live-image" ]
    [ "${#BOOT_CFG[@]}" -eq 1 ]
}

@test "32: merge_feed_env output round-trips through 'source' safely" {
    FEED_ENV="$TMP/feed.env"
    LOCK_FILE="$TMP/lock"
    : > "$FEED_ENV"
    BOOT_CFG=([USER]='Dave Display' [LATITUDE]=51.5)
    merge_feed_env
    set -a
    # shellcheck source=/dev/null
    source "$FEED_ENV"
    set +a
    [ "$USER" = "Dave Display" ]
    [ "$LATITUDE" = "51.5" ]
}

# Helper: install a PATH-prepended mock systemctl that records argv.
mock_systemctl() {
    SYSCTL_LOG="$TMP/sysctl.log"
    : > "$SYSCTL_LOG"
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/systemctl" <<EOF
#!/bin/bash
echo "\$@" >> "$SYSCTL_LOG"
EOF
    chmod +x "$TMP/bin/systemctl"
    PATH="$TMP/bin:$PATH"
}

@test "33: toggle_978_services with DUMP978=yes invokes enable + start --no-block" {
    mock_systemctl
    BOOT_CFG=([DUMP978]=yes)
    toggle_978_services
    grep -Fxq 'enable dump978-fa.service airplanes-978.service' "$SYSCTL_LOG"
    grep -Fxq 'start --no-block dump978-fa.service airplanes-978.service' "$SYSCTL_LOG"
}

@test "34: toggle_978_services with DUMP978=no is a no-op" {
    mock_systemctl
    BOOT_CFG=([DUMP978]=no)
    toggle_978_services
    [ ! -s "$SYSCTL_LOG" ]
}

@test "35: toggle_978_services with DUMP978=YES (uppercase) is a no-op (literal-yes only)" {
    mock_systemctl
    BOOT_CFG=([DUMP978]=YES)
    toggle_978_services
    [ ! -s "$SYSCTL_LOG" ]
}

@test "36: toggle_978_services with DUMP978=true is a no-op (literal-yes only)" {
    mock_systemctl
    BOOT_CFG=([DUMP978]=true)
    toggle_978_services
    [ ! -s "$SYSCTL_LOG" ]
}

@test "37: toggle_978_services with DUMP978 unset is a no-op" {
    mock_systemctl
    BOOT_CFG=()
    toggle_978_services
    [ ! -s "$SYSCTL_LOG" ]
}

# WIFI_* keys must NOT be subject to the shell-metachar reject — common WiFi
# passwords contain $ and \. Those values are written into an NM keyfile, not
# sourced via bash, so the reject would silently degrade WPA-PSK to open. See
# generate_wifi_keyfile in airplanes-first-run for the keyfile path.

@test "38: WIFI_PASS with \$ is preserved (NM keyfile is not eval'd)" {
    echo 'WIFI_PASS="my$pass"' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[WIFI_PASS]}" = 'my$pass' ]
}

@test "39: WIFI_PASS with backslash is preserved" {
    echo 'WIFI_PASS="my\\pass"' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[WIFI_PASS]}" = 'my\\pass' ]
}

@test "40: WIFI_PASS with backtick is preserved" {
    echo 'WIFI_PASS="back`tick"' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[WIFI_PASS]}" = 'back`tick' ]
}

@test "41: WIFI_SSID with \$ is preserved" {
    echo 'WIFI_SSID="net$work"' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[WIFI_SSID]}" = 'net$work' ]
}

@test "42: non-WIFI key with \$ is still rejected" {
    echo 'USER="some$thing"' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ ! -v "BOOT_CFG[USER]" ]
}

@test "43: WIFI_COUNTRY=DE parses (validation happens at consume_wifi_config)" {
    echo "WIFI_COUNTRY=DE" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[WIFI_COUNTRY]}" = "DE" ]
}
