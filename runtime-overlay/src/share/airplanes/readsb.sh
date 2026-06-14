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

# --- SDR-pin hardware gate ---------------------------------------------------
# When a 1090 SDR serial is pinned (two-SDR setups), probe for the dongle
# before exec'ing readsb. If it isn't present, self-disable (publish the
# decision, sleep, exit 0) instead of letting readsb die and restart-loop
# every RestartSec with no diagnostic. Restart=always re-runs the wrapper so a
# hot-plugged dongle is picked up on the next cycle. Mirrors the no_hardware
# path in airplanes/dump978-fa.sh. Single-SDR (no pin) and net-only
# (DUMP1090=no) feeders skip the probe entirely and behave exactly as before.
#
# The probe is presence-only and non-mutating: it reads
# /sys/bus/usb/devices/*/serial and never invokes rtl_eeprom (a *setter*). A
# present-but-busy dongle is NOT detected here and will still restart-loop —
# same limitation as dump978-fa; a pin that collides with the 978 serial is
# caught earlier by the webconfig validator.
: "${READSB_RUNTIME_DIR:=/run/readsb}"
: "${STATE_WRITER_LIB:=/usr/local/share/airplanes/lib/state-writer.sh}"
# Probe override: glob expanded for USB serial files. Tests point this at a
# temp dir; production reads /sys/bus/usb/devices/*/serial.
: "${READSB_USB_SERIAL_GLOB:=/sys/bus/usb/devices/*/serial}"
# Test-only sleep override — keeps the production no_hardware cycle short
# enough to pick up a hot-plug within ~75s. Don't set in feed.env: 0 +
# Restart=always = restart storm.
: "${READSB_NO_HARDWARE_SLEEP:=60}"

STATE_FILE="$READSB_RUNTIME_DIR/state"

# State writer library. Defensive: if the lib is missing (mid-update or an
# older overlay), the decoder must still start correctly — a missing state
# file degrades render-status/webconfig to systemd-only rendering, the
# existing fallback path.
if [[ -r "$STATE_WRITER_LIB" ]]; then
	# shellcheck source=/dev/null
	source "$STATE_WRITER_LIB"
else
	airplanes_write_state() { return 0; }
fi

mkdir -p "$READSB_RUNTIME_DIR"

# Non-mutating probe: scan USB device serials for an exact match. Returns 0
# when a device with the requested serial is present. Guarded conditionals
# only (no naked grep/pipeline) so a non-matching glob can't trip `set -e`
# before the decision is published. Glob is allowed not to match.
_readsb_probe_serial() {
	local want="$1" f have
	[[ -n "$want" ]] || return 1
	# shellcheck disable=SC2086
	for f in $READSB_USB_SERIAL_GLOB; do
		[[ -r "$f" ]] || continue
		have="$(cat "$f" 2>/dev/null)" || continue
		[[ "$have" == "$want" ]] && return 0
	done
	return 1
}

# Echo "<state> <reason>". reason ∈ {ok, no_hardware}. net-only and
# single-SDR are enabled/ok (deliberate config, not a fault) and skip the
# probe; only a pinned-but-absent dongle self-disables.
_readsb_classify() {
	if [[ "$DUMP1090" == "no" || -z "$READSB_SDR_SERIAL" ]]; then
		printf 'enabled ok\n'
		return
	fi
	if _readsb_probe_serial "$READSB_SDR_SERIAL"; then
		printf 'enabled ok\n'
	else
		printf 'disabled no_hardware\n'
	fi
}

read -r STATE REASON < <(_readsb_classify)

airplanes_write_state "$STATE_FILE" \
	"service=readsb" \
	"state=$STATE" \
	"reason=$REASON" \
	"decided_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	"sdr_serial=${READSB_SDR_SERIAL}" || true

if [[ "$STATE" == "disabled" ]]; then
	printf 'No RTL-SDR with serial=%q present; not starting readsb decoder.\n' \
		"$READSB_SDR_SERIAL" >&2
	# || true so a malformed sleep value can't trip `set -e` before exit 0
	# (which would defeat the self-disable and restart-loop anyway).
	sleep "$READSB_NO_HARDWARE_SLEEP" || true
	exit 0
fi
# --- end SDR-pin hardware gate -----------------------------------------------

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
