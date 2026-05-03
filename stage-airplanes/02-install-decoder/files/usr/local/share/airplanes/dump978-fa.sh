#!/bin/bash
set -e

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

exec /usr/bin/dump978-fa \
	--sdr driver=rtlsdr,serial="$DUMP978_SDR_SERIAL" \
	--sdr-gain "$DUMP978_GAIN" \
	--format CS8 \
	--raw-port "${DUMP978_RAW_BIND}:30978" \
	--json-port "${DUMP978_JSON_BIND}:30979"
