#!/bin/bash
set -e

# /etc/airplanes/feed.env may not include readsb-related keys (feed/install.sh
# only writes LATITUDE/LONGITUDE/ALTITUDE/MLAT_USER/MLAT_ENABLED). Defaults
# below are the safe production values; webconfig writes the rest later.
GAIN="${GAIN:-auto}"
LATITUDE="${LATITUDE:-0}"
LONGITUDE="${LONGITUDE:-0}"
DUMP1090="${DUMP1090:-yes}"
READSB_SDR_SERIAL="${READSB_SDR_SERIAL:-}"
# Decoder-scoped pass-through. Deliberately NOT named NET_OPTIONS: legacy
# /etc/default/airplanes carried a feeder-tuned NET_OPTIONS with
# --net-bo-port 0 / --net-ri-port 0 / --net-sbs-port 0 to suppress the
# combined binary's output ports; reusing that name here would clobber
# 30005/30001/30003 on migrated feeders. 30104 is the canonical Beast-input
# port for mlat-client feedback (mlat-client routes --results
# beast,connect,127.0.0.1:30104 here so MLAT planes appear locally in
# tar1090/graphs1090). 30004 is open as a courtesy local-Beast input for
# co-resident processes. Both listeners inherit --net-bind-address
# 127.0.0.1 below, so they're loopback-only.
READSB_NET_OPTIONS="${READSB_NET_OPTIONS:-"--net-bi-port 30004,30104"}"

# Build the operator-controllable bag FIRST so the hardcoded args after it
# win on repeated flags (readsb's argp uses last-wins). This is the safety
# invariant: an operator-set READSB_NET_OPTIONS="--net-bind-address 0.0.0.0"
# can NOT defeat the loopback bind below. Use `read -ra` instead of
# unquoted expansion so a value containing shell globs (*, ?) isn't
# pathname-expanded against CWD.
read -ra _readsb_net_opts <<<"$READSB_NET_OPTIONS"
args=( "${_readsb_net_opts[@]}" )
args+=(
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
	--write-json-every 0.5
	--json-location-accuracy 2
	--write-json-globe-index
	--write-globe-history /var/globe_history
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

# Test seam — mirrors the ${AIRPLANES_PYTHON_BIN} pattern in feed's
# scripts/lib/update-builds.sh so bats can intercept the exec without PATH
# manipulation. Production behavior unchanged when READSB_BIN is unset.
READSB_BIN="${READSB_BIN:-/usr/bin/readsb}"
exec "$READSB_BIN" "${args[@]}"
