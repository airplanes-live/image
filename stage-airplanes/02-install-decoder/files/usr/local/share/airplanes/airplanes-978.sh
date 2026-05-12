#!/bin/bash
# Wrapper for airplanes-978 (UAT relay). Reads UAT_INPUT from the
# EnvironmentFile-loaded environment to decide whether to run, and
# publishes that decision to /run/airplanes-978/state for consumers
# (apl-feed status, render-status, webconfig dashboard).
#
# Decision matrix (state, reason):
#   UAT_INPUT == ""              → disabled, uat_disabled       (exit 64)
#   UAT_INPUT == "127.0.0.1:30978" + peer (dump978-fa) is idle for no_hardware
#                                → enabled, peer_no_hardware    (exec daemon, relay idle)
#   UAT_INPUT == "127.0.0.1:30978" → enabled, ok                (exec daemon)
#   anything else                → misconfigured, uat_input_invalid (exit 64)
#
# Exit 64 paired with RestartPreventExitStatus=64 in the unit file marks
# the service failed terminal so systemd does not restart-loop on the
# self-disable. Symmetric with airplanes-mlat.sh.
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
# keeps the state file across the failed terminal state (so consumers can read
# decision=disabled), but we don't want to keep serving stale aircraft.json
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
        exit 64
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
