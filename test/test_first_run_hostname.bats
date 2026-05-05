#!/usr/bin/env bats

# Tests for apply_hostname in airplanes-first-run.
#
# HOSTNAME is a user-friendly synthetic key in airplanes-config.txt. When set,
# apply_hostname validates it as an RFC 1123 single-label name, writes
# /etc/hostname atomically, rewrites the 127.0.1.1 entry in /etc/hosts so
# mDNS broadcasts the new name, and unsets BOOT_CFG[HOSTNAME] so it never
# leaks into feed.env.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/06-firstboot/files/usr/local/sbin/airplanes-first-run"
    TMP="$(mktemp -d)"
    export HOSTNAME_FILE="$TMP/hostname"
    export HOSTS_FILE="$TMP/hosts"
    # Default fixture state: hostname=raspberrypi, hosts has the canonical
    # 127.0.1.1 line. Tests override as needed.
    printf 'raspberrypi\n' > "$HOSTNAME_FILE"
    cat > "$HOSTS_FILE" <<'EOF'
127.0.0.1	localhost
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters

127.0.1.1	raspberrypi
EOF
    declare -gA BOOT_CFG=()
    # shellcheck source=/dev/null
    source "$SCRIPT"
    BOOT_CFG=()
}

teardown() { rm -rf "$TMP"; }

@test "01: empty BOOT_CFG -> no-op (hostname unchanged)" {
    apply_hostname
    [ "$(cat "$HOSTNAME_FILE")" = "raspberrypi" ]
}

@test "02: HOSTNAME unset -> no-op" {
    BOOT_CFG=([LATITUDE]=51.5)
    apply_hostname
    [ "$(cat "$HOSTNAME_FILE")" = "raspberrypi" ]
    [ "${BOOT_CFG[LATITUDE]}" = "51.5" ]
}

@test "03: simple alphanumeric hostname is applied" {
    BOOT_CFG=([HOSTNAME]="feeder1")
    apply_hostname
    [ "$(cat "$HOSTNAME_FILE")" = "feeder1" ]
    [ ! -v "BOOT_CFG[HOSTNAME]" ]
}

@test "04: hostname with internal hyphens is applied" {
    BOOT_CFG=([HOSTNAME]="airplanes-feeder")
    apply_hostname
    [ "$(cat "$HOSTNAME_FILE")" = "airplanes-feeder" ]
}

@test "05: 63-char hostname (max valid length) is applied" {
    local h
    h="$(printf 'a%.0s' {1..63})"
    BOOT_CFG=([HOSTNAME]="$h")
    apply_hostname
    [ "$(cat "$HOSTNAME_FILE")" = "$h" ]
}

@test "06: 64-char hostname is rejected" {
    local h
    h="$(printf 'a%.0s' {1..64})"
    BOOT_CFG=([HOSTNAME]="$h")
    apply_hostname 2>/dev/null
    [ "$(cat "$HOSTNAME_FILE")" = "raspberrypi" ]
    [ ! -v "BOOT_CFG[HOSTNAME]" ]
}

@test "07: leading-hyphen hostname is rejected" {
    BOOT_CFG=([HOSTNAME]="-foo")
    apply_hostname 2>/dev/null
    [ "$(cat "$HOSTNAME_FILE")" = "raspberrypi" ]
}

@test "08: trailing-hyphen hostname is rejected" {
    BOOT_CFG=([HOSTNAME]="foo-")
    apply_hostname 2>/dev/null
    [ "$(cat "$HOSTNAME_FILE")" = "raspberrypi" ]
}

@test "09: dotted hostname (multi-label) is rejected" {
    # mDNS adds .local automatically; users specifying foo.local would get
    # foo.local.local broadcast. Reject to surface the mistake at first boot.
    BOOT_CFG=([HOSTNAME]="airplanes-feeder.local")
    apply_hostname 2>/dev/null
    [ "$(cat "$HOSTNAME_FILE")" = "raspberrypi" ]
}

@test "10: underscore in hostname is rejected (RFC 1123)" {
    BOOT_CFG=([HOSTNAME]="bad_host")
    apply_hostname 2>/dev/null
    [ "$(cat "$HOSTNAME_FILE")" = "raspberrypi" ]
}

@test "11: shell metachar in hostname is rejected" {
    # parse_boot_config rejects \$ \\ \" \` already; this is the second
    # gate for chars like ; & < that slip through and would land in argv.
    BOOT_CFG=([HOSTNAME]="bad;rm")
    apply_hostname 2>/dev/null
    [ "$(cat "$HOSTNAME_FILE")" = "raspberrypi" ]
}

@test "12: digit-only hostname is accepted (RFC 1123)" {
    # RFC 1123 explicitly relaxed RFC 952's letter-must-start rule.
    BOOT_CFG=([HOSTNAME]="123")
    apply_hostname
    [ "$(cat "$HOSTNAME_FILE")" = "123" ]
}

@test "13: idempotent: HOSTNAME matches current /etc/hostname -> no-op but key still stripped" {
    printf 'feeder1\n' > "$HOSTNAME_FILE"
    BOOT_CFG=([HOSTNAME]="feeder1")
    apply_hostname
    [ "$(cat "$HOSTNAME_FILE")" = "feeder1" ]
    [ ! -v "BOOT_CFG[HOSTNAME]" ]
}

@test "14: /etc/hosts 127.0.1.1 line gets the new hostname" {
    BOOT_CFG=([HOSTNAME]="feeder1")
    apply_hostname
    grep -qP '^127\.0\.1\.1\tfeeder1$' "$HOSTS_FILE"
    # Old line gone.
    run grep -q $'^127\\.0\\.1\\.1\traspberrypi$' "$HOSTS_FILE"
    [ "$status" -ne 0 ]
}

@test "15: /etc/hosts 127.0.0.1 localhost line untouched" {
    BOOT_CFG=([HOSTNAME]="feeder1")
    apply_hostname
    grep -qP '^127\.0\.0\.1\tlocalhost$' "$HOSTS_FILE"
}

@test "16: /etc/hosts ipv6 lines untouched" {
    BOOT_CFG=([HOSTNAME]="feeder1")
    apply_hostname
    grep -qF '::1' "$HOSTS_FILE"
    grep -qF 'ff02::1' "$HOSTS_FILE"
    grep -qF 'ff02::2' "$HOSTS_FILE"
}

@test "17: /etc/hosts 127.0.1.1 line with aliases preserves the aliases" {
    cat > "$HOSTS_FILE" <<'EOF'
127.0.1.1	raspberrypi rpi alias3
EOF
    BOOT_CFG=([HOSTNAME]="feeder1")
    apply_hostname
    grep -qP '^127\.0\.1\.1\tfeeder1 rpi alias3$' "$HOSTS_FILE"
}

@test "18: /etc/hosts 127.0.1.1 for a different hostname is left alone" {
    cat > "$HOSTS_FILE" <<'EOF'
127.0.1.1	some-other-name
127.0.1.1	raspberrypi
EOF
    BOOT_CFG=([HOSTNAME]="feeder1")
    apply_hostname
    # only the matching line gets rewritten
    grep -qP '^127\.0\.1\.1\tsome-other-name$' "$HOSTS_FILE"
    grep -qP '^127\.0\.1\.1\tfeeder1$' "$HOSTS_FILE"
}

@test "19: missing /etc/hosts -> /etc/hostname still written, no error" {
    rm -f "$HOSTS_FILE"
    BOOT_CFG=([HOSTNAME]="feeder1")
    apply_hostname
    [ "$(cat "$HOSTNAME_FILE")" = "feeder1" ]
    [ ! -e "$HOSTS_FILE" ]
}

@test "20: missing /etc/hostname -> apply still creates it" {
    rm -f "$HOSTNAME_FILE"
    BOOT_CFG=([HOSTNAME]="feeder1")
    apply_hostname
    [ "$(cat "$HOSTNAME_FILE")" = "feeder1" ]
}

@test "21: HOSTNAME never reaches feed.env via merge" {
    FEED_ENV="$TMP/feed.env"
    LOCK_FILE="$TMP/lock"
    : > "$FEED_ENV"
    BOOT_CFG=([HOSTNAME]="feeder1" [LATITUDE]="51.5")
    apply_hostname
    merge_feed_env
    run grep -q '^HOSTNAME=' "$FEED_ENV"
    [ "$status" -ne 0 ]
    grep -qP '^LATITUDE="51.5"$' "$FEED_ENV"
}

@test "22: shipped template (HOSTNAME commented) -> no hostname change" {
    local template
    template="$BATS_TEST_DIRNAME/../stage-airplanes/06-firstboot/files/boot/firmware/airplanes-config.txt"
    parse_boot_config "$template"
    apply_hostname
    [ "$(cat "$HOSTNAME_FILE")" = "raspberrypi" ]
    [ ! -v "BOOT_CFG[HOSTNAME]" ]
}
