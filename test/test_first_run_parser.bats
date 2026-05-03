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

@test "10: sentinel USER=changeme is filtered" {
    echo "USER=changeme" > "$FIXTURE"
    parse_boot_config "$FIXTURE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
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

@test "25: mixed real + sentinel keeps only the real one" {
    cat > "$FIXTURE" <<'EOF'
LATITUDE=0
LONGITUDE=-0.1
USER=changeme
DUMP978=yes
EOF
    parse_boot_config "$FIXTURE"
    [ "${BOOT_CFG[LONGITUDE]}" = "-0.1" ]
    [ "${BOOT_CFG[DUMP978]}" = "yes" ]
    [ "${#BOOT_CFG[@]}" -eq 2 ]
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

@test "31: shipped airplanes-config.txt template parses to empty BOOT_CFG" {
    # Alignment guard: if anyone adds a non-sentinel default to the template
    # OR removes a key from SENTINELS while leaving it in the template, this
    # test fails immediately.
    parse_boot_config "$TEMPLATE"
    [ "${#BOOT_CFG[@]}" -eq 0 ]
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
