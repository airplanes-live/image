#!/bin/bash
# Wrapper for dump978-fa (978 MHz UAT receiver). Reads UAT_INPUT and
# DUMP978_SDR_SERIAL from the EnvironmentFile-loaded environment, runs a
# non-mutating USB-serial probe so the daemon does not thrash on hardware
# without a 978 dongle, and publishes the decision to /run/dump978-fa/state
# for consumers (apl-feed status, render-status, webconfig dashboard).
#
# Decision matrix (state, reason):
#   UAT_INPUT == ""                                → disabled, uat_disabled        (sleep + exit 0)
#   UAT_INPUT == "127.0.0.1:30978" + no matching SDR → disabled, no_hardware       (sleep + exit 0)
#   UAT_INPUT == "127.0.0.1:30978" + matching SDR    → enabled, ok                 (exec daemon)
#   anything else                                  → misconfigured, uat_input_invalid (exit 64)
#
# Disabled states sleep then exit 0 so systemd reports the unit as active
# (matching airplanes-mlat.sh's pattern) instead of failed; Restart=always
# in the unit re-runs us after the sleep so a hot-plug picks up on the
# next cycle. The state file is written before the sleep, so consumers
# see the decision immediately. Misconfigured keeps exit 64 paired with
# RestartPreventExitStatus=64 so real operator errors surface as failed
# in `systemctl status` instead of being silently masked.
#
# Sleep durations are tuned per reason: no_hardware uses a short cycle
# so plugging in the 978 SDR is auto-picked up within ~60s; uat_disabled
# uses a long cycle (there's nothing to poll for). Both are env-overridable
# for the bats suite — DUMP978_FA_DISABLED_SLEEP / DUMP978_FA_NO_HARDWARE_SLEEP
# are test-only knobs (do not set in feed.env: 0 would create a restart
# storm with Restart=always).
#
# Hardware probe is intentionally non-mutating: reads /sys/bus/usb/devices/*/serial
# rather than invoking `rtl_eeprom -s` (which is a *setter* — running it would
# overwrite the SDR's EEPROM-stored serial).
set -e

UAT_INPUT="${UAT_INPUT-}"

# 978 conventionally lives on a second SDR flashed with serial "978" via:
#   sudo apt install rtl-sdr && rtl_eeprom -s 00000978
# Override DUMP978_SDR_SERIAL in /etc/airplanes/feed.env (or via webconfig) if
# the user provisioned a different serial.
DUMP978_SDR_SERIAL="${DUMP978_SDR_SERIAL:-978}"
DUMP978_GAIN="${DUMP978_GAIN:-42.1}"
DUMP978_RAW_BIND="${DUMP978_RAW_BIND:-127.0.0.1}"
DUMP978_JSON_BIND="${DUMP978_JSON_BIND:-127.0.0.1}"

# Test hooks. Bats overrides these to skip real /run paths and stub the binary.
: "${DUMP978_FA_RUNTIME_DIR:=/run/dump978-fa}"
: "${DUMP978_FA_BIN:=/usr/bin/dump978-fa}"
: "${STATE_WRITER_LIB:=/usr/local/share/airplanes/lib/state-writer.sh}"
# Probe override: glob expanded for USB serial files. Tests point this at a
# temp dir; production reads /sys/bus/usb/devices/*/serial.
: "${DUMP978_FA_USB_SERIAL_GLOB:=/sys/bus/usb/devices/*/serial}"
# Test-only sleep overrides — see the header comment. Default values keep
# production behaviour; bats sets these to 0 so wrapper invocations return
# promptly. Don't override in feed.env: 0 + Restart=always = restart storm.
: "${DUMP978_FA_DISABLED_SLEEP:=3600}"
: "${DUMP978_FA_NO_HARDWARE_SLEEP:=60}"

STATE_FILE="$DUMP978_FA_RUNTIME_DIR/state"

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

mkdir -p "$DUMP978_FA_RUNTIME_DIR"

# Non-mutating probe: scan USB device serials for a match. Returns 0 when
# a device with the requested serial is present. Glob is allowed not to
# match (no devices yet enumerated → return 1 → no_hardware).
_dump978_fa_probe_serial() {
    local want="$1" f have
    [[ -n "$want" ]] || return 1
    # shellcheck disable=SC2086
    for f in $DUMP978_FA_USB_SERIAL_GLOB; do
        [[ -r "$f" ]] || continue
        have="$(cat "$f" 2>/dev/null)" || continue
        [[ "$have" == "$want" ]] && return 0
    done
    return 1
}

_dump978_fa_classify() {
    case "$UAT_INPUT" in
        "")
            printf 'disabled uat_disabled\n'
            return
            ;;
        "127.0.0.1:30978")
            ;;
        *)
            printf 'misconfigured uat_input_invalid\n'
            return
            ;;
    esac
    if _dump978_fa_probe_serial "$DUMP978_SDR_SERIAL"; then
        printf 'enabled ok\n'
    else
        printf 'disabled no_hardware\n'
    fi
}

read -r STATE REASON < <(_dump978_fa_classify)

airplanes_write_state "$STATE_FILE" \
    "service=dump978-fa" \
    "state=$STATE" \
    "reason=$REASON" \
    "decided_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "uat_input=${UAT_INPUT}" \
    "sdr_serial=${DUMP978_SDR_SERIAL}" || true

case "$STATE" in
    disabled)
        case "$REASON" in
            uat_disabled)
                echo "UAT disabled (UAT_INPUT empty); not starting dump978-fa." >&2
                sleep "$DUMP978_FA_DISABLED_SLEEP"
                ;;
            no_hardware)
                printf 'No RTL-SDR with serial=%q present; not starting dump978-fa.\n' \
                    "$DUMP978_SDR_SERIAL" >&2
                sleep "$DUMP978_FA_NO_HARDWARE_SLEEP"
                ;;
        esac
        exit 0
        ;;
    misconfigured)
        printf 'UAT_INPUT=%q invalid; must be "" or "127.0.0.1:30978".\n' "$UAT_INPUT" >&2
        exit 64
        ;;
    enabled)
        ;;
esac

# dump978-fa accepts [host:]port for --raw-port / --json-port. Default-bind
# localhost so the ports aren't LAN-exposed; override via env if a tar1090 978
# instance on another host needs to scrape directly.
exec "$DUMP978_FA_BIN" \
	--sdr driver=rtlsdr,serial="$DUMP978_SDR_SERIAL" \
	--sdr-gain "$DUMP978_GAIN" \
	--format CS8 \
	--raw-port "${DUMP978_RAW_BIND}:30978" \
	--json-port "${DUMP978_JSON_BIND}:30979"
