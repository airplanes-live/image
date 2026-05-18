#!/bin/bash
# Reconcile tar1090's ENABLE_978 with the airplanes-978 + dump978-fa runtime
# state. Driven by airplanes-tar1090-uat-sync.path (watches /run/airplanes-978/state
# and /run/dump978-fa/state) and run once at boot via the matching .service.
#
# tar1090's main loop tries to prune 978.json on every iteration when
# ENABLE_978=yes and emits "978.json: No such file or directory" through bash's
# redirect handler when the file isn't there. The file only exists when
# airplanes-978's readsb instance is actually relaying UAT JSON, which itself
# requires dump978-fa to be enabled + the 978 SDR present. Anything short of
# that should leave ENABLE_978=no so tar1090 keeps quiet.
#
# Truth source: the producer's runtime state file. airplanes-978's own
# state.reason==peer_no_hardware is sampled once at wrapper start and goes
# stale on hot-plug, so we ignore it and re-check dump978-fa.state
# directly.
#
# Decision matrix (desired ENABLE_978):
#   consumer.state != enabled               → no
#   producer.state != enabled               → no
#   producer.reason != ok                   → no
#   both enabled + producer.ok              → yes
#
# Idempotent. Reads /etc/default/tar1090, rewrites only when the value
# changes, restarts tar1090 only on transition.
set -eu

# Test hooks — bats overrides these to stub paths and the restart command.
: "${AIRPLANES_TAR1090_DEFAULTS_PATH:=/etc/default/tar1090}"
: "${AIRPLANES_978_STATE_PATH:=/run/airplanes-978/state}"
: "${DUMP978_FA_STATE_PATH:=/run/dump978-fa/state}"
: "${AIRPLANES_TAR1090_SYNC_RESTART_CMD:=systemctl try-restart tar1090.service}"
: "${STATE_READER_LIB:=/usr/local/share/airplanes/lib/state-reader.sh}"

# State reader library. Defensive fallback: a missing lib means we can't
# read the state files, which we treat the same as "absent" → desired=no.
if [[ -r "$STATE_READER_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_READER_LIB"
else
    airplanes_read_state() { return 1; }
fi

read_field() {
    local file="$1" key="$2"
    [[ -r "$file" ]] || return 0
    airplanes_read_state "$file" "$key" 2>/dev/null || true
}

compute_desired() {
    local consumer_state producer_state producer_reason
    consumer_state="$(read_field "$AIRPLANES_978_STATE_PATH" state)"
    producer_state="$(read_field "$DUMP978_FA_STATE_PATH" state)"
    producer_reason="$(read_field "$DUMP978_FA_STATE_PATH" reason)"
    if [[ "$consumer_state" == "enabled" \
        && "$producer_state" == "enabled" \
        && "$producer_reason" == "ok" ]]; then
        printf 'yes\n'
    else
        printf 'no\n'
    fi
}

current_enable_978() {
    # Match the first uncommented ENABLE_978= line. If none, return empty so
    # the awk rewrite below knows to append rather than substitute.
    [[ -r "$AIRPLANES_TAR1090_DEFAULTS_PATH" ]] || return 0
    awk -F= '/^[[:space:]]*ENABLE_978=/ { sub(/^[[:space:]]*ENABLE_978=/, "", $0); print; exit }' \
        "$AIRPLANES_TAR1090_DEFAULTS_PATH"
}

rewrite_enable_978() {
    local desired="$1" src dst
    src="$AIRPLANES_TAR1090_DEFAULTS_PATH"
    dst="${src}.tar1090-uat-sync.tmp.$$"
    # Substitute the first ENABLE_978= line in place; append one if none
    # exists. Anchored to ^ so commented-out forms (#ENABLE_978=...) are
    # left untouched.
    awk -v val="$desired" '
        BEGIN { done = 0 }
        /^ENABLE_978=/ && !done { print "ENABLE_978=" val; done = 1; next }
        { print }
        END { if (!done) print "ENABLE_978=" val }
    ' "$src" > "$dst"
    # Preserve mode + owner from the original file.
    chmod --reference="$src" "$dst"
    chown --reference="$src" "$dst" 2>/dev/null || true
    mv -f "$dst" "$src"
}

main() {
    local desired current
    desired="$(compute_desired)"
    current="$(current_enable_978)"
    if [[ "$current" == "$desired" ]]; then
        exit 0
    fi
    rewrite_enable_978 "$desired"
    # Use try-restart so this script is safe to run before tar1090 has
    # been started for the first time (oneshot service runs at boot, may
    # fire before multi-user.target.wants/tar1090.service is active).
    # shellcheck disable=SC2086
    $AIRPLANES_TAR1090_SYNC_RESTART_CMD
}

main "$@"
