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

@test "07: literal LATITUDE=0 propagates (no sentinel filter)" {
    # PR 4.5 retired the sentinel pattern; optional keys are now commented
    # out in the template. Any uncommented value is treated as user-set,
    # including a literal zero (the user knowingly set it).
    echo "LATITUDE=0" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[LATITUDE]}" = "0" ]
}

@test "08: literal LONGITUDE=0 propagates" {
    echo "LONGITUDE=0" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[LONGITUDE]}" = "0" ]
}

@test "09: literal ALTITUDE=0m propagates" {
    echo "ALTITUDE=0m" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[ALTITUDE]}" = "0m" ]
}

@test "10: MLAT_USER propagates" {
    # MLAT_USER ships uncommented in the template so unconfigured feeders
    # show identifiably on the MLAT map instead of taking feed.env's
    # generic placeholder.
    echo "MLAT_USER=airplanes-live-image" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[MLAT_USER]}" = "airplanes-live-image" ]
    [ "${#BOOT_CFG[@]}" -eq 1 ]
}

@test "11: DUMP978=no propagates (no longer a sentinel; legacy translation handles it)" {
    # DUMP978 used to be sentinel-filtered, but PR 4 retired the legacy 978
    # toggle. Both DUMP978=no and DUMP978=yes now propagate through parse_boot_config;
    # apply_dump978_to_uat_input is the gate that translates DUMP978=yes into
    # UAT_INPUT and unsets DUMP978 entirely.
    echo "DUMP978=no" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[DUMP978]}" = "no" ]
}

@test "12: DUMP978=yes propagates" {
    echo "DUMP978=yes" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[DUMP978]}" = "yes" ]
}

@test "13: LATITUDE=0.5 propagates verbatim" {
    echo "LATITUDE=0.5" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[LATITUDE]}" = "0.5" ]
}

@test "14: LATITUDE=0.0 propagates verbatim" {
    # PR 4.5: with sentinels retired, literal "0" / "0.0" / "0m" all
    # propagate the same way — the user uncommented the key, so the value
    # is intent.
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

@test "19: unquoted value with trailing space is trimmed" {
    printf 'LATITUDE=0 \n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[LATITUDE]}" = "0" ]
}

@test "20: unquoted value with surrounding whitespace is trimmed" {
    printf 'LATITUDE=  0  \n' > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[LATITUDE]}" = "0" ]
}

@test "21: quoted value with trailing space preserves whitespace verbatim" {
    # Quoted values express explicit intent — do NOT trim.
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

@test "25: every uncommented key propagates verbatim" {
    # No sentinel filtering after PR 4.5 — uncommented values are user intent,
    # including literal zero. Comments and blank lines are still skipped.
    cat > "$FIXTURE" <<'EOF'
LATITUDE=0
LONGITUDE=-0.1
MLAT_USER=airplanes-live-image
DUMP978=yes
EOF
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[LATITUDE]}" = "0" ]
    [ "${BOOT_CFG[LONGITUDE]}" = "-0.1" ]
    [ "${BOOT_CFG[MLAT_USER]}" = "airplanes-live-image" ]
    [ "${BOOT_CFG[DUMP978]}" = "yes" ]
    [ "${#BOOT_CFG[@]}" -eq 4 ]
}

# ---- DUMP978 → UAT_INPUT translation (apply_dump978_to_uat_input) ----------

@test "30: apply_dump978_to_uat_input: DUMP978=yes alone → UAT_INPUT=127.0.0.1:30978" {
    BOOT_CFG=()
    BOOT_CFG[DUMP978]="yes"
    apply_dump978_to_uat_input
    [ "${BOOT_CFG[UAT_INPUT]}" = "127.0.0.1:30978" ]
    [ ! -v "BOOT_CFG[DUMP978]" ]
}

@test "31: apply_dump978_to_uat_input: DUMP978=no alone → UAT_INPUT not set, DUMP978 unset" {
    BOOT_CFG=()
    BOOT_CFG[DUMP978]="no"
    apply_dump978_to_uat_input
    [ ! -v "BOOT_CFG[UAT_INPUT]" ]
    [ ! -v "BOOT_CFG[DUMP978]" ]
}

@test "32: apply_dump978_to_uat_input: explicit UAT_INPUT=127.0.0.1:30978 wins over DUMP978=no" {
    BOOT_CFG=()
    BOOT_CFG[DUMP978]="no"
    BOOT_CFG[UAT_INPUT]="127.0.0.1:30978"
    apply_dump978_to_uat_input
    [ "${BOOT_CFG[UAT_INPUT]}" = "127.0.0.1:30978" ]
    [ ! -v "BOOT_CFG[DUMP978]" ]
}

@test "33: apply_dump978_to_uat_input: explicit empty UAT_INPUT wins over DUMP978=yes" {
    BOOT_CFG=()
    BOOT_CFG[DUMP978]="yes"
    BOOT_CFG[UAT_INPUT]=""
    apply_dump978_to_uat_input
    [ -v "BOOT_CFG[UAT_INPUT]" ]
    [ "${BOOT_CFG[UAT_INPUT]}" = "" ]
    [ ! -v "BOOT_CFG[DUMP978]" ]
}

@test "34: apply_dump978_to_uat_input: invalid UAT_INPUT is dropped (DUMP978=yes then maps to default)" {
    BOOT_CFG=()
    BOOT_CFG[UAT_INPUT]="10.0.0.5:30978"
    BOOT_CFG[DUMP978]="yes"
    apply_dump978_to_uat_input
    [ "${BOOT_CFG[UAT_INPUT]}" = "127.0.0.1:30978" ]
    [ ! -v "BOOT_CFG[DUMP978]" ]
}

@test "35: apply_dump978_to_uat_input: invalid UAT_INPUT is dropped, no DUMP978 → no UAT_INPUT" {
    BOOT_CFG=()
    BOOT_CFG[UAT_INPUT]="evil-host;rm -rf /"
    apply_dump978_to_uat_input
    [ ! -v "BOOT_CFG[UAT_INPUT]" ]
}

@test "36: apply_dump978_to_uat_input: empty BOOT_CFG → no-op" {
    BOOT_CFG=()
    apply_dump978_to_uat_input
    [ "${#BOOT_CFG[@]}" -eq 0 ]
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

@test "31: shipped airplanes-config.txt template parses to MLAT defaults + DUMP978=no" {
    # Alignment guard: if anyone adds a non-commented key to the template
    # OR changes the MLAT defaults, this fails.
    # PR 4.5: optional keys (LATITUDE/LONGITUDE/ALTITUDE/UAT_INPUT/etc.)
    # ship commented out; the only uncommented values are MLAT_USER,
    # MLAT_ENABLED, and DUMP978=no. apply_dump978_to_uat_input strips DUMP978
    # downstream, leaving feed.env with just the MLAT keys.
    parse_boot_config "$TEMPLATE"
    [ "${BOOT_CFG[MLAT_USER]}" = "airplanes-live-image" ]
    [ "${BOOT_CFG[MLAT_ENABLED]}" = "true" ]
    [ "${BOOT_CFG[DUMP978]}" = "no" ]
    [ "${#BOOT_CFG[@]}" -eq 3 ]
}

@test "32: merge_feed_env output round-trips through 'source' safely" {
    FEED_ENV="$TMP/feed.env"
    LOCK_FILE="$TMP/lock"
    : > "$FEED_ENV"
    BOOT_CFG=([MLAT_USER]='Dave Display' [LATITUDE]=51.5)
    merge_feed_env
    set -a
    # shellcheck source=/dev/null
    source "$FEED_ENV"
    set +a
    [ "$MLAT_USER" = "Dave Display" ]
    [ "$LATITUDE" = "51.5" ]
}

# --- apply_user_to_mlat_split ---

@test "33a: apply_user_to_mlat_split: USER=name -> MLAT_USER=name + MLAT_ENABLED=true, USER unset" {
    BOOT_CFG=([USER]='alice')
    apply_user_to_mlat_split
    [ "${BOOT_CFG[MLAT_USER]}" = "alice" ]
    [ "${BOOT_CFG[MLAT_ENABLED]}" = "true" ]
    [ -z "${BOOT_CFG[USER]+set}" ]
}

@test "33b: apply_user_to_mlat_split: USER=0 -> MLAT_USER='', MLAT_ENABLED=false" {
    BOOT_CFG=([USER]='0')
    apply_user_to_mlat_split
    [ "${BOOT_CFG[MLAT_USER]}" = "" ]
    [ "${BOOT_CFG[MLAT_ENABLED]}" = "false" ]
    [ -z "${BOOT_CFG[USER]+set}" ]
}

@test "33c: apply_user_to_mlat_split: USER=disable -> MLAT_USER='', MLAT_ENABLED=false" {
    BOOT_CFG=([USER]='disable')
    apply_user_to_mlat_split
    [ "${BOOT_CFG[MLAT_USER]}" = "" ]
    [ "${BOOT_CFG[MLAT_ENABLED]}" = "false" ]
}

@test "33d: apply_user_to_mlat_split: explicit MLAT_USER wins, USER dropped" {
    BOOT_CFG=([MLAT_USER]='from-new' [USER]='from-legacy')
    apply_user_to_mlat_split
    [ "${BOOT_CFG[MLAT_USER]}" = "from-new" ]
    [ -z "${BOOT_CFG[USER]+set}" ]
}

@test "33e: apply_user_to_mlat_split: explicit MLAT_ENABLED wins, USER dropped" {
    BOOT_CFG=([MLAT_ENABLED]='false' [USER]='alice')
    apply_user_to_mlat_split
    [ "${BOOT_CFG[MLAT_ENABLED]}" = "false" ]
    [ -z "${BOOT_CFG[MLAT_USER]+set}" ] || [ "${BOOT_CFG[MLAT_USER]}" = "" ]
    [ -z "${BOOT_CFG[USER]+set}" ]
}

@test "33f: apply_user_to_mlat_split: no USER, no MLAT_* -> no-op" {
    BOOT_CFG=([LATITUDE]=51.5)
    apply_user_to_mlat_split
    [ -z "${BOOT_CFG[USER]+set}" ]
    [ -z "${BOOT_CFG[MLAT_USER]+set}" ]
    [ -z "${BOOT_CFG[MLAT_ENABLED]+set}" ]
    [ "${BOOT_CFG[LATITUDE]}" = "51.5" ]
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

# PR 4 retired toggle_978_services — the 978 units are systemctl-enabled at
# install time and self-disable via exit 64 when UAT_INPUT is empty/invalid.
# DUMP978 → UAT_INPUT translation is now apply_dump978_to_uat_input, covered
# by tests 30-36 above; tests 33-37 (toggle_978_services systemctl invocations)
# were removed with that function.

@test "37: toggle_978_services is no longer defined (PR 4 retired the function)" {
    ! type -t toggle_978_services >/dev/null 2>&1
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
