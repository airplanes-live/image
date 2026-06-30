#!/bin/bash
# Reconcile tar1090's ENABLE_978 with the airplanes-978 + dump978-fa runtime
# state. Driven by airplanes-tar1090-uat-sync.path (watches /run/airplanes/978/state
# and /run/airplanes/dump978-fa/state) and run once at boot via the matching .service.
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
: "${AIRPLANES_978_STATE_PATH:=/run/airplanes/978/state}"
: "${DUMP978_FA_STATE_PATH:=/run/airplanes/dump978-fa/state}"
: "${AIRPLANES_TAR1090_SYNC_RESTART_CMD:=systemctl try-restart tar1090.service}"

# State file parser is inline rather than sourced from
# /opt/airplanes/current/share/airplanes/lib/state-reader.sh: that library ships from
# airplanes-live/feed, and (a) the reconcile only needs two fields, (b)
# we need to read each file as a single snapshot to avoid mixing fields
# from different atomic-rename generations, and (c) keeping zero runtime
# deps lets the script work on pre-feed-state-lib images too.
read_field_from() {
    # Extract a key=value field from a state-file snapshot held in a string.
    # Mirrors airplanes_read_state's contract but operates on captured
    # content rather than re-reading the file (which would let the atomic-
    # rename writer swap files between successive reads and let us mix
    # values from different generations).
    local snapshot="$1" key="$2"
    [[ -n "$snapshot" ]] || return 1
    local first=1 line
    while IFS= read -r line; do
        if (( first )); then
            first=0
            [[ "$line" == 'schema_version=1' ]] || return 1
            continue
        fi
        case "$line" in
            "${key}="*)
                printf '%s' "${line#"${key}="}"
                return 0
                ;;
        esac
    done <<<"$snapshot"
    return 1
}

read_snapshot() {
    # Read the named state file once into stdout. A subsequent atomic rename
    # by the wrapper does not affect what we already captured. Empty stdout
    # is the correct "absent or unreadable" signal — the field extractor
    # treats that as "no value".
    local file="$1"
    [[ -r "$file" ]] || return 0
    cat -- "$file" 2>/dev/null || true
}

compute_desired() {
    local consumer_snapshot producer_snapshot
    local consumer_state producer_state producer_reason
    consumer_snapshot="$(read_snapshot "$AIRPLANES_978_STATE_PATH")"
    producer_snapshot="$(read_snapshot "$DUMP978_FA_STATE_PATH")"
    consumer_state="$(read_field_from "$consumer_snapshot" state || true)"
    producer_state="$(read_field_from "$producer_snapshot" state || true)"
    producer_reason="$(read_field_from "$producer_snapshot" reason || true)"
    if [[ "$consumer_state" == "enabled" \
        && "$producer_state" == "enabled" \
        && "$producer_reason" == "ok" ]]; then
        printf 'yes\n'
    else
        printf 'no\n'
    fi
}

current_enable_978() {
    # Match the first uncommented ENABLE_978= line. The regex is anchored at
    # column 0 (no leading-whitespace tolerance) to stay symmetric with the
    # rewriter — an indented assignment would otherwise be read here but
    # ignored by the rewrite, leaving the two views out of sync.
    [[ -r "$AIRPLANES_TAR1090_DEFAULTS_PATH" ]] || return 0
    awk -F= '/^ENABLE_978=/ { sub(/^ENABLE_978=/, "", $0); print; exit }' \
        "$AIRPLANES_TAR1090_DEFAULTS_PATH"
}

rewrite_enable_978() {
    local desired="$1" src dst
    src="$AIRPLANES_TAR1090_DEFAULTS_PATH"
    dst="${src}.tar1090-uat-sync.tmp.$$"
    # Replace EVERY uncommented ENABLE_978= line with the canonical value.
    # If sourced as a shell file the last assignment wins, so a stray
    # duplicate left behind would override our reconciled value. Append a
    # single assignment at EOF when no occurrences existed. Commented forms
    # (#ENABLE_978=...) are anchored out and left untouched.
    awk -v val="$desired" '
        BEGIN { seen = 0 }
        /^ENABLE_978=/ { print "ENABLE_978=" val; seen = 1; next }
        { print }
        END { if (!seen) print "ENABLE_978=" val }
    ' "$src" > "$dst"
    # Preserve mode + owner from the original file. GNU coreutils only;
    # Debian trixie (this image's base) is GNU.
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
    # `|| true` because a masked or broken tar1090 unit shouldn't propagate
    # under set -e and mark this reconcile service failed — the config
    # change is the load-bearing effect; the restart is a convenience.
    # shellcheck disable=SC2086
    $AIRPLANES_TAR1090_SYNC_RESTART_CMD || true
}

main "$@"
