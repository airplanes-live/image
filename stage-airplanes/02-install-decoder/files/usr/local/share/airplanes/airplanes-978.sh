#!/bin/bash
set -e

LATITUDE="${LATITUDE:-0}"
LONGITUDE="${LONGITUDE:-0}"

# silent_fail on the connector: dump978-fa restarts or is absent during 978-off
# state shouldn't spam logs. With Wants=dump978-fa.service (non-blocking),
# silent_fail is the right safety net.
exec /usr/bin/airplanes-978 \
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
	--write-json /run/airplanes-978 \
	--quiet
