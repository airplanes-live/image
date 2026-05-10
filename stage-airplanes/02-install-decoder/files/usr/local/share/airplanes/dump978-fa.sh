#!/bin/bash
# Wrapper for dump978-fa (978 MHz UAT receiver). Reads UAT_INPUT from the
# EnvironmentFile-loaded environment and self-disables (exit 64 paired
# with RestartPreventExitStatus=64) when UAT is not requested. State
# publication is owned by airplanes-978.sh; this wrapper only performs
# the same self-disable check so the receiver doesn't run when UAT is off.
#
# Decision matrix matches airplanes-978.sh:
#   UAT_INPUT == ""              → exit 64
#   UAT_INPUT == "127.0.0.1:30978" → exec
#   anything else                → exit 64
set -e

UAT_INPUT="${UAT_INPUT-}"

# Test hook: bats tests override to skip the real binary.
: "${DUMP978_FA_BIN:=/usr/bin/dump978-fa}"

case "$UAT_INPUT" in
    "")
        echo "UAT disabled (UAT_INPUT empty); not starting dump978-fa." >&2
        exit 64
        ;;
    "127.0.0.1:30978")
        ;;
    *)
        printf 'UAT_INPUT=%q invalid; not starting dump978-fa.\n' "$UAT_INPUT" >&2
        exit 64
        ;;
esac

# 978 conventionally lives on a second SDR flashed with serial "978" via:
#   sudo apt install rtl-sdr && rtl_eeprom -s 00000978
# Override DUMP978_SDR_SERIAL in /etc/airplanes/feed.env (or via webconfig) if
# the user provisioned a different serial.
DUMP978_SDR_SERIAL="${DUMP978_SDR_SERIAL:-978}"
DUMP978_GAIN="${DUMP978_GAIN:-42.1}"
# dump978-fa accepts [host:]port for --raw-port / --json-port. Default-bind
# localhost so the ports aren't LAN-exposed; override via env if a tar1090 978
# instance on another host needs to scrape directly.
DUMP978_RAW_BIND="${DUMP978_RAW_BIND:-127.0.0.1}"
DUMP978_JSON_BIND="${DUMP978_JSON_BIND:-127.0.0.1}"

exec "$DUMP978_FA_BIN" \
	--sdr driver=rtlsdr,serial="$DUMP978_SDR_SERIAL" \
	--sdr-gain "$DUMP978_GAIN" \
	--format CS8 \
	--raw-port "${DUMP978_RAW_BIND}:30978" \
	--json-port "${DUMP978_JSON_BIND}:30979"
