#!/bin/bash
set -e

# /etc/airplanes/feed.env may not include readsb-related keys (feed/install.sh
# only writes LATITUDE/LONGITUDE/ALTITUDE/USER). Defaults below are the safe
# production values; webconfig writes the rest later.
GAIN="${GAIN:-auto}"
LATITUDE="${LATITUDE:-0}"
LONGITUDE="${LONGITUDE:-0}"
DUMP1090="${DUMP1090:-yes}"
READSB_SDR_SERIAL="${READSB_SDR_SERIAL:-}"

args=(
	--net-bind-address 127.0.0.1
	--net
	--net-bo-port 30005
	--net-ri-port 30001
	--net-sbs-port 30003
	--net-api-port 30152
	--net-json-port 30154
	--write-prom /run/readsb/stats.prom
	--lat "$LATITUDE"
	--lon "$LONGITUDE"
	--max-range 600
	--aircraft-update-interval 0.5
	--json-location-accuracy 2
)

if [[ "$DUMP1090" == "no" ]]; then
	args+=( --net-only )
else
	args+=( --device-type rtlsdr --gain "$GAIN" )
	# Two-SDR setups need explicit selection so readsb doesn't grab the 978
	# dongle. Leave unset for single-SDR (default) behavior.
	[[ -n "$READSB_SDR_SERIAL" ]] && args+=( --device "$READSB_SDR_SERIAL" )
fi

args+=( --write-json /run/readsb --quiet )
exec /usr/bin/readsb "${args[@]}"
