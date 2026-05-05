#!/usr/bin/env bats

# Tests for expand_feed_host in airplanes-first-run.
#
# FEED_HOST is a user-friendly shorthand the user uncomments in
# airplanes-config.txt to point a feeder at a non-production backend (homelab
# / cloned airplanes.live setup) without having to know the readsb
# --net-connector syntax. expand_feed_host derives MLATSERVER and TARGET from
# it, respects explicit user overrides, and unsets FEED_HOST so the synthetic
# key never reaches feed.env.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/06-firstboot/files/usr/local/sbin/airplanes-first-run"
    declare -gA BOOT_CFG=()
    # shellcheck source=/dev/null
    source "$SCRIPT"
    BOOT_CFG=()
}

@test "01: empty BOOT_CFG -> no-op" {
    expand_feed_host
    [ "${#BOOT_CFG[@]}" -eq 0 ]
}

@test "02: FEED_HOST unset -> no MLATSERVER/TARGET synthesized" {
    BOOT_CFG=([LATITUDE]=51.5)
    expand_feed_host
    [ ! -v "BOOT_CFG[MLATSERVER]" ]
    [ ! -v "BOOT_CFG[TARGET]" ]
    [ "${BOOT_CFG[LATITUDE]}" = "51.5" ]
}

@test "03: bare hostname derives both endpoints with default ports" {
    BOOT_CFG=([FEED_HOST]="mybackend.local")
    expand_feed_host
    [ "${BOOT_CFG[MLATSERVER]}" = "mybackend.local:31090" ]
    [ "${BOOT_CFG[TARGET]}" = "--net-connector mybackend.local,30004,beast_reduce_plus_out" ]
    [ ! -v "BOOT_CFG[FEED_HOST]" ]
}

@test "04: hostname:port overrides only the mlat port (beast stays 30004)" {
    BOOT_CFG=([FEED_HOST]="mybackend.local:9999")
    expand_feed_host
    [ "${BOOT_CFG[MLATSERVER]}" = "mybackend.local:9999" ]
    [ "${BOOT_CFG[TARGET]}" = "--net-connector mybackend.local,30004,beast_reduce_plus_out" ]
}

@test "05: bare IPv4 address works" {
    BOOT_CFG=([FEED_HOST]="10.0.0.5")
    expand_feed_host
    [ "${BOOT_CFG[MLATSERVER]}" = "10.0.0.5:31090" ]
    [ "${BOOT_CFG[TARGET]}" = "--net-connector 10.0.0.5,30004,beast_reduce_plus_out" ]
}

@test "06: IPv4:port works" {
    BOOT_CFG=([FEED_HOST]="10.0.0.5:9999")
    expand_feed_host
    [ "${BOOT_CFG[MLATSERVER]}" = "10.0.0.5:9999" ]
    [ "${BOOT_CFG[TARGET]}" = "--net-connector 10.0.0.5,30004,beast_reduce_plus_out" ]
}

@test "07: explicit MLATSERVER override is respected; TARGET still derived" {
    BOOT_CFG=([FEED_HOST]="mybackend.local" [MLATSERVER]="other.example:1234")
    expand_feed_host
    [ "${BOOT_CFG[MLATSERVER]}" = "other.example:1234" ]
    [ "${BOOT_CFG[TARGET]}" = "--net-connector mybackend.local,30004,beast_reduce_plus_out" ]
    [ ! -v "BOOT_CFG[FEED_HOST]" ]
}

@test "08: explicit TARGET override is respected; MLATSERVER still derived" {
    BOOT_CFG=(
        [FEED_HOST]="mybackend.local"
        [TARGET]="--net-connector first.example,30004,beast_reduce_plus_out,second.example,64004"
    )
    expand_feed_host
    [ "${BOOT_CFG[MLATSERVER]}" = "mybackend.local:31090" ]
    [ "${BOOT_CFG[TARGET]}" = "--net-connector first.example,30004,beast_reduce_plus_out,second.example,64004" ]
    [ ! -v "BOOT_CFG[FEED_HOST]" ]
}

@test "09: both overrides set; FEED_HOST still stripped" {
    BOOT_CFG=(
        [FEED_HOST]="mybackend.local"
        [MLATSERVER]="other.example:1234"
        [TARGET]="--net-connector custom"
    )
    expand_feed_host
    [ "${BOOT_CFG[MLATSERVER]}" = "other.example:1234" ]
    [ "${BOOT_CFG[TARGET]}" = "--net-connector custom" ]
    [ ! -v "BOOT_CFG[FEED_HOST]" ]
}

@test "10: bracketed IPv6 is rejected (use MLATSERVER/TARGET directly)" {
    BOOT_CFG=([FEED_HOST]="[2001:db8::1]")
    expand_feed_host 2>/dev/null
    [ ! -v "BOOT_CFG[MLATSERVER]" ]
    [ ! -v "BOOT_CFG[TARGET]" ]
    [ ! -v "BOOT_CFG[FEED_HOST]" ]
}

@test "11: hostname with space is rejected" {
    BOOT_CFG=([FEED_HOST]="my backend.local")
    expand_feed_host 2>/dev/null
    [ ! -v "BOOT_CFG[MLATSERVER]" ]
    [ ! -v "BOOT_CFG[TARGET]" ]
}

@test "12: hostname with shell metachar is rejected (defense in depth past parse)" {
    # parse_boot_config already rejects $; this is the second-line gate that
    # catches anything else that might slip through (e.g. ;, &, <, >, # in
    # values that bypassed the parser).
    BOOT_CFG=([FEED_HOST]="foo;rm")
    expand_feed_host 2>/dev/null
    [ ! -v "BOOT_CFG[MLATSERVER]" ]
    [ ! -v "BOOT_CFG[TARGET]" ]
}

@test "13: non-numeric port is rejected" {
    BOOT_CFG=([FEED_HOST]="mybackend.local:abc")
    expand_feed_host 2>/dev/null
    [ ! -v "BOOT_CFG[MLATSERVER]" ]
    [ ! -v "BOOT_CFG[TARGET]" ]
}

@test "13a: port 0 is rejected (out of TCP range)" {
    BOOT_CFG=([FEED_HOST]="mybackend.local:0")
    expand_feed_host 2>/dev/null
    [ ! -v "BOOT_CFG[MLATSERVER]" ]
    [ ! -v "BOOT_CFG[TARGET]" ]
}

@test "13b: port 65535 (max valid) is accepted" {
    BOOT_CFG=([FEED_HOST]="mybackend.local:65535")
    expand_feed_host
    [ "${BOOT_CFG[MLATSERVER]}" = "mybackend.local:65535" ]
    [ "${BOOT_CFG[TARGET]}" = "--net-connector mybackend.local,30004,beast_reduce_plus_out" ]
}

@test "13c: port 65536 is rejected (one past TCP max)" {
    BOOT_CFG=([FEED_HOST]="mybackend.local:65536")
    expand_feed_host 2>/dev/null
    [ ! -v "BOOT_CFG[MLATSERVER]" ]
    [ ! -v "BOOT_CFG[TARGET]" ]
}

@test "13d: large multi-digit port is rejected" {
    BOOT_CFG=([FEED_HOST]="mybackend.local:9999999")
    expand_feed_host 2>/dev/null
    [ ! -v "BOOT_CFG[MLATSERVER]" ]
    [ ! -v "BOOT_CFG[TARGET]" ]
}

@test "13e: leading-zero port (e.g. 08) is normalized and accepted" {
    # bash arithmetic would interpret 08 as octal and error; we strip leading
    # zeros before the range check to prevent the failure.
    BOOT_CFG=([FEED_HOST]="mybackend.local:08")
    expand_feed_host
    # The MLATSERVER value preserves what the user wrote; only the range
    # check normalizes. Acceptable — it's the user's syntax.
    [ "${BOOT_CFG[MLATSERVER]}" = "mybackend.local:08" ]
}

@test "14: empty FEED_HOST string is treated as unset" {
    # parse_boot_config already drops empty values, but be defensive.
    BOOT_CFG=([FEED_HOST]="")
    expand_feed_host
    [ ! -v "BOOT_CFG[MLATSERVER]" ]
    [ ! -v "BOOT_CFG[TARGET]" ]
}

@test "15: FEED_HOST > 253 bytes (DNS hostname max) rejected" {
    BOOT_CFG=([FEED_HOST]="$(printf 'a%.0s' {1..254})")
    expand_feed_host 2>/dev/null
    [ ! -v "BOOT_CFG[MLATSERVER]" ]
    [ ! -v "BOOT_CFG[TARGET]" ]
}

@test "16: FEED_HOST exactly 253 bytes is accepted" {
    local host
    host="$(printf 'a%.0s' {1..253})"
    BOOT_CFG=([FEED_HOST]="$host")
    expand_feed_host
    [ "${BOOT_CFG[MLATSERVER]}" = "${host}:31090" ]
}

@test "17: synthesized values pass webconfig universalReject character set" {
    # configspec.go:53 forbids " \ $ ` ; & | < > # \n \r \0 ' in any
    # preserved value when webconfig later writes feed.env. The synthesized
    # MLATSERVER and TARGET must not contain any of those characters.
    BOOT_CFG=([FEED_HOST]="mybackend.local")
    expand_feed_host
    [[ "${BOOT_CFG[MLATSERVER]}" != *[\"\$\`\;\&\|\<\>\#\']* ]]
    [[ "${BOOT_CFG[TARGET]}" != *[\"\$\`\;\&\|\<\>\#\']* ]]
}

@test "18: integration with parse_boot_config: FEED_HOST line in file -> derived endpoints in BOOT_CFG" {
    local fixture
    fixture="$(mktemp)"
    printf 'FEED_HOST=test.local\nLATITUDE=51.5\n' > "$fixture"
    parse_boot_config "$fixture"
    expand_feed_host
    [ "${BOOT_CFG[MLATSERVER]}" = "test.local:31090" ]
    [ "${BOOT_CFG[TARGET]}" = "--net-connector test.local,30004,beast_reduce_plus_out" ]
    [ ! -v "BOOT_CFG[FEED_HOST]" ]
    [ "${BOOT_CFG[LATITUDE]}" = "51.5" ]
    rm -f "$fixture"
}

@test "19: shipped template (FEED_HOST commented) does not produce derived endpoints" {
    local template
    template="$BATS_TEST_DIRNAME/../stage-airplanes/06-firstboot/files/boot/firmware/airplanes-config.txt"
    parse_boot_config "$template"
    expand_feed_host
    [ ! -v "BOOT_CFG[MLATSERVER]" ]
    [ ! -v "BOOT_CFG[TARGET]" ]
    [ ! -v "BOOT_CFG[FEED_HOST]" ]
}

@test "21: invalid FEED_HOST + lone MLATSERVER -> MLATSERVER dropped (no asymmetric leak)" {
    # The asymmetric-leak guard codex flagged: an invalid FEED_HOST plus only
    # MLATSERVER set explicitly would leave TARGET pointing at production.
    # We drop the lone MLATSERVER instead so both endpoints fall back to
    # defaults, keeping routing symmetric.
    BOOT_CFG=([FEED_HOST]="bad..invalid$" [MLATSERVER]="lab:31090")
    expand_feed_host 2>/dev/null
    [ ! -v "BOOT_CFG[FEED_HOST]" ]
    [ ! -v "BOOT_CFG[MLATSERVER]" ]
    [ ! -v "BOOT_CFG[TARGET]" ]
}

@test "22: invalid FEED_HOST + lone TARGET -> TARGET dropped" {
    BOOT_CFG=([FEED_HOST]="bad invalid" [TARGET]="--net-connector lab,30004,beast_reduce_plus_out")
    expand_feed_host 2>/dev/null
    [ ! -v "BOOT_CFG[FEED_HOST]" ]
    [ ! -v "BOOT_CFG[MLATSERVER]" ]
    [ ! -v "BOOT_CFG[TARGET]" ]
}

@test "23: invalid FEED_HOST + matched MLATSERVER+TARGET pair -> pair preserved" {
    # User explicitly set both endpoints; the FEED_HOST typo doesn't justify
    # dropping a self-contained advanced override.
    BOOT_CFG=(
        [FEED_HOST]="[2001:db8::1]"
        [MLATSERVER]="lab:31090"
        [TARGET]="--net-connector lab,30004,beast_reduce_plus_out"
    )
    expand_feed_host 2>/dev/null
    [ ! -v "BOOT_CFG[FEED_HOST]" ]
    [ "${BOOT_CFG[MLATSERVER]}" = "lab:31090" ]
    [ "${BOOT_CFG[TARGET]}" = "--net-connector lab,30004,beast_reduce_plus_out" ]
}

@test "24: invalid FEED_HOST + neither override -> all endpoints fall back to defaults (no-op)" {
    BOOT_CFG=([FEED_HOST]="bad invalid")
    expand_feed_host 2>/dev/null
    [ ! -v "BOOT_CFG[FEED_HOST]" ]
    [ ! -v "BOOT_CFG[MLATSERVER]" ]
    [ ! -v "BOOT_CFG[TARGET]" ]
}

@test "20: round-trip through merge_feed_env produces sourceable feed.env" {
    local tmpdir feed_env
    tmpdir="$(mktemp -d)"
    feed_env="$tmpdir/feed.env"
    : > "$feed_env"
    FEED_ENV="$feed_env"
    LOCK_FILE="$tmpdir/lock"
    BOOT_CFG=([FEED_HOST]="test.local")
    expand_feed_host
    merge_feed_env

    # Source the resulting feed.env in a subshell and assert the values land
    # in the env exactly as the runtime feed scripts will see them.
    (
        set -a
        # shellcheck source=/dev/null
        source "$feed_env"
        set +a
        [ "$MLATSERVER" = "test.local:31090" ]
        [ "$TARGET" = "--net-connector test.local,30004,beast_reduce_plus_out" ]
        [ -z "${FEED_HOST:-}" ]
    )
    rm -rf "$tmpdir"
}
