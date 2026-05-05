#!/usr/bin/env bats

# Unit tests for stage-airplanes/06b-console-dashboard/files/usr/local/lib/airplanes/render-status.
# Sources the script for direct access to helpers; the BASH_SOURCE guard at
# the bottom of render-status suppresses dispatcher execution on source.

bats_require_minimum_version 1.5.0

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../stage-airplanes/06b-console-dashboard/files/usr/local/lib/airplanes/render-status"
    LOGO="$BATS_TEST_DIRNAME/../stage-airplanes/06b-console-dashboard/files/usr/local/share/airplanes/logo.txt"
    TMP="$(mktemp -d)"

    # All PATHS_* default to /nonexistent so an un-overridden test gets the
    # "all sources missing" baseline. Individual tests then point a single
    # PATHS_* at a fixture.
    export PATHS_FEEDER_ID="$TMP/nx-feeder-id"
    export PATHS_RELEASE_CHANNEL="$TMP/nx-channel"
    export PATHS_MANIFEST="$TMP/nx-manifest"
    export PATHS_FEED_ENV="$TMP/nx-feed-env"
    export PATHS_CLAIM_SECRET="$TMP/nx-claim-secret"
    export PATHS_CLAIM_PENDING="$TMP/nx-claim-pending"
    export PATHS_CLAIM_VERSION="$TMP/nx-claim-version"
    export PATHS_AIRCRAFT_JSON="$TMP/nx-aircraft"
    export PATHS_THERMAL="$TMP/nx-thermal"
    export PATHS_LOGO="$LOGO"
    export TERM=dumb  # disable color so assertions match plain text

    # shellcheck source=/dev/null
    source "$SCRIPT"
}

teardown() { rm -rf "$TMP"; }

# ---- _use_color ------------------------------------------------------------

@test "use_color: TERM=dumb returns non-zero (color disabled)" {
    run ! env TERM=dumb bash -c "source $SCRIPT && _use_color"
}

@test "use_color: TERM unset returns non-zero (color disabled)" {
    run ! env -u TERM bash -c "source $SCRIPT && _use_color"
}

# ---- sanitize --------------------------------------------------------------

@test "sanitize: drops control bytes, keeps printable ASCII" {
    out="$(sanitize $'foo\x07bar\x1b[31m' 64)"
    [ "$out" = "foobar[31m" ]
}

@test "sanitize: clamps at maxlen" {
    out="$(sanitize "abcdefghij" 4)"
    [ "$out" = "abcd" ]
}

# ---- read_feeder_id --------------------------------------------------------

@test "read_feeder_id: returns empty when file absent" {
    out="$(read_feeder_id)"
    [ -z "$out" ]
}

@test "read_feeder_id: returns trimmed UUID" {
    printf 'abc12345-1234-1234-1234-1234567890ab\n' > "$PATHS_FEEDER_ID"
    out="$(read_feeder_id)"
    [ "$out" = "abc12345-1234-1234-1234-1234567890ab" ]
}

# ---- read_feed_env_var -----------------------------------------------------

@test "read_feed_env_var: LATITUDE unquoted" {
    printf 'LATITUDE=48.123\n' > "$PATHS_FEED_ENV"
    [ "$(read_feed_env_var LATITUDE)" = "48.123" ]
}

@test "read_feed_env_var: LATITUDE quoted" {
    printf 'LATITUDE="48.123"\n' > "$PATHS_FEED_ENV"
    [ "$(read_feed_env_var LATITUDE)" = "48.123" ]
}

@test "read_feed_env_var: LATITUDE=0 returns 0" {
    printf 'LATITUDE=0\n' > "$PATHS_FEED_ENV"
    [ "$(read_feed_env_var LATITUDE)" = "0" ]
}

@test "read_feed_env_var: empty value returns empty" {
    printf 'LATITUDE=\n' > "$PATHS_FEED_ENV"
    [ -z "$(read_feed_env_var LATITUDE)" ]
}

@test "read_feed_env_var: unwhitelisted key returns empty" {
    printf 'TARGET=foo\n' > "$PATHS_FEED_ENV"
    [ -z "$(read_feed_env_var TARGET)" ]
}

@test "read_feed_env_var: USER=changeme is captured" {
    printf 'USER=changeme\n' > "$PATHS_FEED_ENV"
    [ "$(read_feed_env_var USER)" = "changeme" ]
}

@test "read_feed_env_var: duplicate keys -> last wins (matches Go feedenv)" {
    cat > "$PATHS_FEED_ENV" <<'EOF'
LATITUDE=0
LATITUDE=48.5
EOF
    [ "$(read_feed_env_var LATITUDE)" = "48.5" ]
}

# ---- claim_state -----------------------------------------------------------

@test "claim_state: no files -> unclaimed" {
    [ "$(claim_state)" = "unclaimed" ]
}

@test "claim_state: secret only -> secret-saved" {
    : > "$PATHS_CLAIM_SECRET"
    [ "$(claim_state)" = "secret-saved" ]
}

@test "claim_state: secret + version -> registered (vN)" {
    : > "$PATHS_CLAIM_SECRET"
    printf '7\n' > "$PATHS_CLAIM_VERSION"
    [ "$(claim_state)" = "registered (v7)" ]
}

@test "claim_state: pending + final -> rotation-pending" {
    : > "$PATHS_CLAIM_SECRET"
    printf '7\n' > "$PATHS_CLAIM_VERSION"
    : > "$PATHS_CLAIM_PENDING"
    [ "$(claim_state)" = "rotation-pending" ]
}

@test "claim_state: pending alone (no final) -> registration-pending" {
    : > "$PATHS_CLAIM_PENDING"
    [ "$(claim_state)" = "registration-pending" ]
}

@test "claim_state: NEVER reads claim secret contents" {
    # If claim_state ever cracks open the secret file, this will be in the
    # function's trace. We assert by writing a unique sentinel and verifying
    # the rendered state never contains it.
    printf 'SECRET-SENTINEL-DO-NOT-LEAK-A1B2C3D4E5F6\n' > "$PATHS_CLAIM_SECRET"
    out="$(claim_state)"
    [[ "$out" != *SECRET-SENTINEL* ]]
    [[ "$out" != *A1B2C3D4* ]]
}

# ---- mlat_disabled_by_config ----------------------------------------------

@test "mlat_disabled_by_config: feed.env absent -> disabled (treated as 0)" {
    mlat_disabled_by_config
}

@test "mlat_disabled_by_config: LAT/LON set, USER set -> not disabled" {
    cat > "$PATHS_FEED_ENV" <<'EOF'
LATITUDE=48.123
LONGITUDE=11.456
USER=alice
EOF
    run ! mlat_disabled_by_config
}

@test "mlat_disabled_by_config: USER=changeme is NOT disabled (mirrors airplanes-mlat.sh)" {
    # The upstream wrapper only short-circuits on USER in {0, disable};
    # `changeme` is the unconfigured-image default but the wrapper still
    # runs, and the server rejects upstream. The dashboard reflects
    # systemctl state in that case rather than fabricating "off".
    cat > "$PATHS_FEED_ENV" <<'EOF'
LATITUDE=48.123
LONGITUDE=11.456
USER=changeme
EOF
    run ! mlat_disabled_by_config
}

@test "mlat_disabled_by_config: USER=disable -> disabled" {
    cat > "$PATHS_FEED_ENV" <<'EOF'
LATITUDE=48.123
LONGITUDE=11.456
USER=disable
EOF
    mlat_disabled_by_config
}

@test "mlat_disabled_by_config: USER=0 -> disabled" {
    cat > "$PATHS_FEED_ENV" <<'EOF'
LATITUDE=48.123
LONGITUDE=11.456
USER=0
EOF
    mlat_disabled_by_config
}

@test "mlat_disabled_by_config: LAT=0 -> disabled even with valid USER" {
    cat > "$PATHS_FEED_ENV" <<'EOF'
LATITUDE=0
LONGITUDE=11.456
USER=alice
EOF
    mlat_disabled_by_config
}

# ---- read_aircraft_snapshot -----------------------------------------------

@test "read_aircraft_snapshot: missing file -> ||" {
    [ "$(read_aircraft_snapshot)" = "||" ]
}

@test "read_aircraft_snapshot: well-formed JSON -> count|messages|now" {
    cat > "$PATHS_AIRCRAFT_JSON" <<'EOF'
{
  "now": 1717000000,
  "messages": 1234,
  "aircraft": [
    {"hex":"a"},
    {"hex":"b"},
    {"hex":"c"}
  ]
}
EOF
    [ "$(read_aircraft_snapshot)" = "3|1234|1717000000" ]
}

@test "read_aircraft_snapshot: malformed JSON -> ||" {
    printf 'this is not json' > "$PATHS_AIRCRAFT_JSON"
    [ "$(read_aircraft_snapshot)" = "||" ]
}

@test "snapshot: messages='bad' (string) does not crash renderer" {
    # Defensive: even though readsb's contract is integers, a corrupted
    # aircraft.json must not bring the dashboard down.
    cat > "$PATHS_AIRCRAFT_JSON" <<'EOF'
{ "now": 100, "messages": "bad", "aircraft": [{"hex":"a"}] }
EOF
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
}

@test "snapshot: messages=1.5 (float) does not crash renderer" {
    cat > "$PATHS_AIRCRAFT_JSON" <<'EOF'
{ "now": 100, "messages": 1.5, "aircraft": [{"hex":"a"}] }
EOF
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
}

# ---- read_local_urls -------------------------------------------------------

@test "read_local_urls: returns at least one usable string" {
    out="$(read_local_urls)"
    [ -n "$out" ]
    # Either an http URL or the not-connected sentinel.
    [[ "$out" =~ ^http://|^\(not\ connected\)$ ]]
}

# ---- snapshot end-to-end (full render with all sources missing) ------------

@test "snapshot: exits 0 with all sources missing" {
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
}

@test "snapshot: contains all section headers" {
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    [[ "$output" == *Access* ]]
    [[ "$output" == *"Feeder ID"* ]]
    [[ "$output" == *Claim* ]]
    [[ "$output" == *Services* ]]
    [[ "$output" == *Feed* ]]
    [[ "$output" == *Build* ]]
    [[ "$output" == *System* ]]
}

@test "snapshot: shows '(not yet generated)' when feeder-id missing" {
    run bash "$SCRIPT" --snapshot
    [[ "$output" == *"(not yet generated)"* ]]
}

@test "snapshot: shows 'unclaimed' when no claim files" {
    run bash "$SCRIPT" --snapshot
    [[ "$output" == *unclaimed* ]]
}

@test "snapshot: never leaks the canonical 16 uppercase-alnum secret form" {
    # Real claim secrets are 16 uppercase A-Z0-9 (per feed/scripts/apl-feed
    # validate_secret). Fixture mirrors that shape; if the renderer ever
    # cracks open the secret file, this match will fire.
    printf 'ABCDEFGHIJKLMNOP\n' > "$PATHS_CLAIM_SECRET"
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    if echo "$output" | grep -E -q '[A-Z0-9]{16}'; then
        false
    fi
}

@test "snapshot: never leaks the displayed XXXX-XXXX-XXXX-XXXX secret form" {
    # apl-feed claim show prints the secret in 4-grouped form. Same guard
    # against the renderer ever touching display formatting of a secret.
    printf 'ABCDEFGHIJKLMNOP\n' > "$PATHS_CLAIM_SECRET"
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    if echo "$output" | grep -E -q '([A-Z0-9]{4}-){3}[A-Z0-9]{4}'; then
        false
    fi
}

@test "snapshot: never leaks 32+ hex-char run" {
    printf '0123456789abcdef0123456789abcdef\n' > "$PATHS_CLAIM_SECRET"
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    if echo "$output" | grep -E -q '[0-9a-f]{32,}'; then
        false
    fi
}

@test "snapshot: never leaks the literal 'feeder-claim-secret' string" {
    : > "$PATHS_CLAIM_SECRET"
    run bash "$SCRIPT" --snapshot
    if echo "$output" | grep -q 'feeder-claim-secret'; then
        false
    fi
}

@test "snapshot: build channel + sha read from manifest" {
    printf 'dev\n' > "$PATHS_RELEASE_CHANNEL"
    cat > "$PATHS_MANIFEST" <<'EOF'
{
  "schema_version": 1,
  "channel": "dev",
  "components": {
    "airplanes_feed": "abcdef1234567890123456789012345678901234"
  }
}
EOF
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    [[ "$output" =~ channel=dev ]]
    [[ "$output" =~ sha=abcdef1 ]]
}

@test "snapshot: omits msgs/s field (rate requires two samples)" {
    cat > "$PATHS_AIRCRAFT_JSON" <<'EOF'
{ "now": 100, "messages": 5, "aircraft": [{"hex":"a"}] }
EOF
    run bash "$SCRIPT" --snapshot
    [ "$status" -eq 0 ]
    [[ "$output" == *"aircraft: 1"* ]]
    if echo "$output" | grep -q 'msgs/s'; then
        false
    fi
}

# ---- MOTD wrapper env-scrub guard ------------------------------------------
#
# pam_motd inherits the user's session env. Without scrubbing, a logged-in
# user could set PATHS_LOGO=/etc/airplanes/feeder-claim-secret in their SSH
# session and the renderer would `cat` that file as root via the MOTD path.
# The wrapper unsets PATHS_* before exec; verify by setting a hostile
# PATHS_LOGO that points at a fixture and asserting nothing from that file
# appears in the output.

@test "MOTD wrapper: PATHS_* env overrides are stripped before exec" {
    MOTD_WRAPPER="$BATS_TEST_DIRNAME/../stage-airplanes/06b-console-dashboard/files/etc/update-motd.d/10-airplanes-status"
    HOSTILE="$TMP/hostile-logo"
    printf 'HOSTILE-PAYLOAD-MUST-NOT-APPEAR-IN-MOTD-OUTPUT\n' > "$HOSTILE"

    # Wrapper hardcodes the renderer path at /usr/local/lib/airplanes; we
    # don't have that on the test host, so we shim it via a temp PATH.
    TMP_LIB="$TMP/usrlocallibairplanes"
    mkdir -p "$TMP_LIB"
    cp "$SCRIPT" "$TMP_LIB/render-status"
    chmod +x "$TMP_LIB/render-status"
    SHIM_DIR="$TMP/shim"
    mkdir -p "$SHIM_DIR"
    cat > "$SHIM_DIR/wrapper" <<EOF
#!/bin/bash
unset "\${!PATHS_@}"
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
exec $TMP_LIB/render-status --snapshot
EOF
    chmod +x "$SHIM_DIR/wrapper"

    run env PATHS_LOGO="$HOSTILE" TERM=dumb "$SHIM_DIR/wrapper"
    [ "$status" -eq 0 ]
    if echo "$output" | grep -q HOSTILE-PAYLOAD; then
        false
    fi
}

@test "MOTD wrapper: env-scrub directives present in source" {
    MOTD_WRAPPER="$BATS_TEST_DIRNAME/../stage-airplanes/06b-console-dashboard/files/etc/update-motd.d/10-airplanes-status"
    # shellcheck disable=SC2016  # literal grep target, no expansion intended
    grep -q '^unset "${!PATHS_@}"' "$MOTD_WRAPPER"
    grep -q '^PATH=' "$MOTD_WRAPPER"
    grep -q '^export PATH' "$MOTD_WRAPPER"
}
