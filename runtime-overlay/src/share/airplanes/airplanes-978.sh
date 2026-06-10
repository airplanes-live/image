#!/bin/bash
# Wrapper for airplanes-978 (UAT relay). Reads UAT_INPUT from the
# EnvironmentFile-loaded environment to decide whether to run, and
# publishes that decision to /run/airplanes-978/state for consumers
# (apl-feed status, render-status, webconfig dashboard).
#
# Decision matrix (state, reason):
#   UAT_INPUT == ""              → disabled, uat_disabled       (idle watch, exit 0 on config change)
#   UAT_INPUT == "127.0.0.1:30978" + peer (dump978-fa) is idle for no_hardware
#                                → enabled, peer_no_hardware    (exec daemon, relay idle)
#   UAT_INPUT == "127.0.0.1:30978" → enabled, ok                (exec daemon)
#   anything else                → misconfigured, uat_input_invalid (exit 64)
#
# The uat_disabled branch idles so systemd reports the unit as active
# (matching airplanes-mlat.sh's pattern) instead of failed; the state file
# is written before the idle so consumers see the decision immediately.
# It exits 0 (→ Restart=always re-exec, fresh EnvironmentFile) only when
# feed.env actually changes. The supported config paths (webconfig UI,
# apl-feed apply) restart this unit explicitly when relevant keys change,
# so the watch only serves hand-edited feed.env files. The previous blind
# hourly exit kept the systemd restart counter climbing forever on every
# UAT-less feeder, polluting the per-service restart counts diagnostics
# report. Misconfigured keeps exit 64 paired with RestartPreventExitStatus=64
# so real operator errors surface in `systemctl status`.
#
# AIRPLANES_978_DISABLED_SLEEP is the watch poll interval in seconds; 0 is
# a test-only knob (bats) that makes the disabled branch single-pass.
# Do not set 0 in feed.env: 0 + Restart=always = restart storm.
#
# The peer_no_hardware reason exists so the dashboard can honestly say
# "relay is up but there's no local decoder feeding it" instead of the
# bare "ok" tile that today is misleading on hardware without a 978 SDR.
# Behaviour-wise we still exec the daemon (the silent_fail on the
# net-connector means no log spam when the peer is absent).
set -e

LATITUDE="${LATITUDE:-0}"
LONGITUDE="${LONGITUDE:-0}"
# `${VAR-}` respects "set but empty" — distinguishes user-cleared from unset
# (the EnvironmentFile= form turns absent keys into unset, not empty).
UAT_INPUT="${UAT_INPUT-}"

# Test hooks. Bats overrides these to skip real /run paths and stub the binary.
: "${AIRPLANES_978_RUNTIME_DIR:=/run/airplanes-978}"
: "${AIRPLANES_978_BIN:=/usr/bin/airplanes-978}"
: "${STATE_WRITER_LIB:=/usr/local/share/airplanes/lib/state-writer.sh}"
: "${STATE_READER_LIB:=/usr/local/share/airplanes/lib/state-reader.sh}"
: "${DUMP978_FA_STATE_FILE:=/run/dump978-fa/state}"
: "${AIRPLANES_978_FEED_ENV:=/etc/airplanes/feed.env}"
# Watch poll interval for the disabled branch. Bats sets 0 so wrapper
# invocations return promptly. Not for feed.env (see header comment).
: "${AIRPLANES_978_DISABLED_SLEEP:=60}"
# Non-integer values would crash `sleep` under set -e or busy-loop; fall
# back to the default rather than taking the relay down over a typo. The
# base-10 normalization collapses leading zeros ("00" → "0") so the
# single-pass comparison below can't be bypassed into a zero-second loop.
if [[ "$AIRPLANES_978_DISABLED_SLEEP" =~ ^[0-9]+$ ]]; then
    AIRPLANES_978_DISABLED_SLEEP=$((10#$AIRPLANES_978_DISABLED_SLEEP))
else
    echo "AIRPLANES_978_DISABLED_SLEEP='$AIRPLANES_978_DISABLED_SLEEP' is not a non-negative integer; using 60." >&2
    AIRPLANES_978_DISABLED_SLEEP=60
fi

STATE_FILE="$AIRPLANES_978_RUNTIME_DIR/state"

# State writer library. Defensive: if the lib is missing (mid-update or
# pre-feed-PR-1 image), the daemon must still self-disable correctly —
# not having a state file degrades render-status/webconfig to systemd-only
# rendering, which is the existing fallback path.
if [[ -r "$STATE_WRITER_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_WRITER_LIB"
else
    airplanes_write_state() { return 0; }
fi

# State reader library. Same defensive fallback as the writer — without it
# we lose the peer_no_hardware refinement but still run correctly.
if [[ -r "$STATE_READER_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_READER_LIB"
else
    airplanes_read_state() { return 1; }
fi

mkdir -p "$AIRPLANES_978_RUNTIME_DIR"

# Clean stale lighttpd-served outputs before deciding. RuntimeDirectoryPreserve=yes
# keeps the state file across the sleep so consumers can read
# decision=disabled, but we don't want to keep serving stale aircraft.json
# from a previous enabled-run after the user disables UAT. The binary rewrites
# these on every poll when UAT is enabled, so the gap is bounded.
rm -f "$AIRPLANES_978_RUNTIME_DIR"/*.json

_978_classify() {
    case "$UAT_INPUT" in
        "")                   printf 'disabled uat_disabled\n' ;;
        "127.0.0.1:30978")    printf 'enabled ok\n' ;;
        *)                    printf 'misconfigured uat_input_invalid\n' ;;
    esac
}

# Refine the reason on the enabled branch by consulting dump978-fa's state
# file. If the peer self-disabled because the 978 SDR is absent, surface
# that to consumers as reason=peer_no_hardware so the dashboard can render
# an honest "idle relay" tile instead of a misleading green ok.
_978_refine_reason() {
    local state="$1" reason="$2"
    [[ "$state" == "enabled" ]] || { printf '%s\n' "$reason"; return; }
    local peer_state peer_reason
    peer_state="$(airplanes_read_state "$DUMP978_FA_STATE_FILE" state 2>/dev/null || true)"
    peer_reason="$(airplanes_read_state "$DUMP978_FA_STATE_FILE" reason 2>/dev/null || true)"
    if [[ "$peer_state" == "disabled" && "$peer_reason" == "no_hardware" ]]; then
        printf 'peer_no_hardware\n'
        return
    fi
    printf '%s\n' "$reason"
}

# Fingerprint of the feed.env this unit's EnvironmentFile= loads.
# device:inode:size:mtime:ctime catches atomic-rename replacement (inode
# changes even when the mtime is preserved), in-place rewrites (the
# nanosecond %y/%z forms catch same-size edits within the same second),
# and absence ("missing", so creation counts as a change). stat only needs
# search permission on /etc/airplanes, not read permission on feed.env,
# so this works for the unprivileged service user.
_978_feedenv_fingerprint() {
    stat -c '%d:%i:%s:%y:%z' "$AIRPLANES_978_FEED_ENV" 2>/dev/null || printf 'missing'
}

read -r STATE REASON < <(_978_classify)
REASON="$(_978_refine_reason "$STATE" "$REASON")"

airplanes_write_state "$STATE_FILE" \
    "service=airplanes-978" \
    "state=$STATE" \
    "reason=$REASON" \
    "decided_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "uat_input=${UAT_INPUT}" || true

case "$STATE" in
    disabled)
        echo "UAT disabled (UAT_INPUT empty); not starting airplanes-978." >&2
        # Idle until feed.env changes, then exit 0 so Restart=always
        # re-execs the wrapper with the fresh EnvironmentFile. The `if`
        # form is required: a bare `[[ … ]] && exit 0` evaluating false
        # would abort the loop under set -e.
        FEEDENV_BASELINE="$(_978_feedenv_fingerprint)"
        while :; do
            sleep "$AIRPLANES_978_DISABLED_SLEEP"
            if [[ "$(_978_feedenv_fingerprint)" != "$FEEDENV_BASELINE" ]]; then
                exit 0
            fi
            # Test knob: interval 0 means single-pass (see header comment).
            if [[ "$AIRPLANES_978_DISABLED_SLEEP" == "0" ]]; then
                exit 0
            fi
        done
        ;;
    misconfigured)
        printf 'UAT_INPUT=%q invalid; must be "" or "127.0.0.1:30978".\n' "$UAT_INPUT" >&2
        exit 64
        ;;
    enabled)
        ;;
esac

# silent_fail on the connector: dump978-fa restarts or is absent during 978-off
# state shouldn't spam logs. With Wants=dump978-fa.service (non-blocking),
# silent_fail is the right safety net.
exec "$AIRPLANES_978_BIN" \
	--net-only \
	--max-range 460 \
	--net \
	--net-bind-address 127.0.0.1 \
	--net-heartbeat 60 \
	--net-ro-interval 0.5 \
	--json-location-accuracy 2 \
	--lat "$LATITUDE" \
	--lon "$LONGITUDE" \
	--net-connector 127.0.0.1,30978,uat_in,silent_fail \
	--write-json "$AIRPLANES_978_RUNTIME_DIR" \
	--quiet
