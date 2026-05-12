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

@test "13a: idempotent + stale /etc/hosts -> /etc/hosts repaired" {
    # Partial-prior-run state: /etc/hostname already matches HOSTNAME but
    # /etc/hosts still has the old name. Idempotency must not skip the hosts
    # repair.
    printf 'feeder1\n' > "$HOSTNAME_FILE"
    cat > "$HOSTS_FILE" <<'EOF'
127.0.0.1	localhost
127.0.1.1	feeder1
EOF
    # Note: current=feeder1, raw=feeder1 — sed will produce a no-op rewrite,
    # which is fine. The bug we're guarding against is the function returning
    # before the /etc/hosts pass runs at all.
    BOOT_CFG=([HOSTNAME]="feeder1")
    apply_hostname
    grep -qP '^127\.0\.1\.1\tfeeder1$' "$HOSTS_FILE"
}

@test "13b: localhost is rejected (case-insensitive)" {
    BOOT_CFG=([HOSTNAME]="localhost")
    apply_hostname 2>/dev/null
    [ "$(cat "$HOSTNAME_FILE")" = "raspberrypi" ]
    BOOT_CFG=([HOSTNAME]="LOCALHOST")
    apply_hostname 2>/dev/null
    [ "$(cat "$HOSTNAME_FILE")" = "raspberrypi" ]
    BOOT_CFG=([HOSTNAME]="LocalHost")
    apply_hostname 2>/dev/null
    [ "$(cat "$HOSTNAME_FILE")" = "raspberrypi" ]
}

@test "13c: multi-line /etc/hostname -> /etc/hosts rewrite is skipped (current rejected)" {
    # Defense against a tampered /etc/hostname leaking weirdness into the
    # sed search key. Multi-line content fails _hostname_valid, so current
    # is treated as unknown and we leave /etc/hosts alone.
    printf 'foo\nbar\n' > "$HOSTNAME_FILE"
    BOOT_CFG=([HOSTNAME]="feeder1")
    apply_hostname 2>/dev/null
    [ "$(cat "$HOSTNAME_FILE")" = "feeder1" ]
    # Original /etc/hosts still has the canonical raspberrypi line — we
    # didn't try to match the bogus 'foo' or 'foobar' as a key.
    grep -qP '^127\.0\.1\.1\traspberrypi$' "$HOSTS_FILE"
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

@test "23: /etc/hosts byte-for-byte: comments + tabs + blank lines preserved" {
    # Hand-crafted /etc/hosts with the kinds of structure a user might add.
    # After rewriting only the 127.0.1.1 line, every other byte should be
    # identical to the original.
    cat > "$HOSTS_FILE" <<'EOF'
# user comment
127.0.0.1	localhost
::1		localhost ip6-localhost ip6-loopback

# more aliases:
192.168.1.10	homeserver homeserver.lan
127.0.1.1	raspberrypi
EOF
    local before
    before="$(grep -v '^127\.0\.1\.1' "$HOSTS_FILE")"
    BOOT_CFG=([HOSTNAME]="feeder1")
    apply_hostname
    local after
    after="$(grep -v '^127\.0\.1\.1' "$HOSTS_FILE")"
    [ "$before" = "$after" ]
    grep -qP '^127\.0\.1\.1\tfeeder1$' "$HOSTS_FILE"
}

@test "24: hosts mktemp failure does not block runtime hostname apply" {
    # Mock the legacy `hostname` binary (the runtime fallback path used when
    # systemd-hostnamed isn't running). Lock the hosts directory after
    # seeding so apply_hostname's mktemp inside the /etc/hosts pass fails;
    # the runtime apply must still happen unconditionally afterward.
    local mock_bin="$TMP/mockbin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/hostname" <<'STUB'
#!/bin/sh
echo "$@" >> "$HOSTNAME_LOG"
STUB
    chmod +x "$mock_bin/hostname"
    export HOSTNAME_LOG="$TMP/hostname-invocations.log"
    : > "$HOSTNAME_LOG"
    local saved_path="$PATH"
    export PATH="$mock_bin:$PATH"

    local locked_dir="$TMP/locked"
    mkdir -p "$locked_dir"
    cp "$HOSTS_FILE" "$locked_dir/hosts"
    chmod 0555 "$locked_dir"
    export HOSTS_FILE="$locked_dir/hosts"

    BOOT_CFG=([HOSTNAME]="feeder1")
    apply_hostname 2>/dev/null

    chmod 0755 "$locked_dir"
    export PATH="$saved_path"

    # /etc/hostname was written even though the /etc/hosts mktemp failed.
    [ "$(cat "$HOSTNAME_FILE")" = "feeder1" ]
    # /etc/hosts itself was NOT modified (mktemp failed before the rewrite).
    grep -qP '^127\.0\.1\.1\traspberrypi$' "$HOSTS_FILE"
    # Runtime apply still happened — the codex-flagged behavior.
    grep -qx 'feeder1' "$HOSTNAME_LOG"
}
