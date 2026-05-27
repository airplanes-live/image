#!/bin/bash
# Emit /etc/airplanes/build-manifest.json from per-component SHA sentinels +
# stub-fingerprint + env (CHANNEL, ARCH). Runs OUTSIDE chroot. Strict input
# validation: every required sentinel present; component SHAs are 40-hex
# lowercase; pi-gen is sha[-dirty]|unknown; channel/arch are enums.
#
# Usage: CHANNEL=<stable|dev> ARCH=<arm64|armhf> manifest-generator.sh ROOTFS_DIR

set -euo pipefail

ROOTFS_DIR="${1:?ROOTFS_DIR required}"
: "${CHANNEL:?CHANNEL required}"
: "${ARCH:?ARCH required}"

[[ "$CHANNEL" =~ ^(stable|dev)$ ]] || {
	echo "ERROR: CHANNEL must be 'stable' or 'dev', got: '$CHANNEL'" >&2
	exit 1
}
[[ "$ARCH" =~ ^(arm64|armhf)$ ]] || {
	echo "ERROR: ARCH must be 'arm64' or 'armhf', got: '$ARCH'" >&2
	exit 1
}

SENTINEL_DIR="${ROOTFS_DIR}/etc/airplanes"

validate_sha_value() {
	local key="$1" source="$2" value="$3"
	[[ "$value" =~ ^[0-9a-f]{40}$ ]] || {
		echo "ERROR: $key content not a 40-char lowercase SHA: $source -> '$value'" >&2
		exit 1
	}
}

read_runtime_manifest_sha() {
	local key="$1" component="$2" path="$3" v
	[[ -s "$path" ]] || { echo "ERROR: runtime manifest missing or empty: $path" >&2; exit 1; }
	v="$(jq -er --arg component "$component" '
		.components[$component]
		| if type == "object" then .commit_sha else . end
		| strings
	' "$path")" || {
		echo "ERROR: $key component missing in runtime manifest: $component ($path)" >&2
		exit 1
	}
	validate_sha_value "$key runtime manifest component" "$path:$component" "$v"
	printf '%s' "$v"
}

read_pigen_sentinel() {
	local path="$1" v
	[[ -s "$path" ]] || { echo "ERROR: pi-gen sentinel missing or empty: $path" >&2; exit 1; }
	v="$(cat "$path")"
	[[ "$v" =~ ^([0-9a-f]{40}(-dirty)?|unknown)$ ]] || {
		echo "ERROR: pi-gen sentinel must be SHA[-dirty] or 'unknown': $path -> '$v'" >&2
		exit 1
	}
	printf '%s' "$v"
}

# Sets SF_INVOC, SF_ENABLES, SF_TS as side effect.
parse_fingerprint() {
	local path="$1" line
	[[ -s "$path" ]] || { echo "ERROR: stub fingerprint missing or empty: $path" >&2; exit 1; }
	line="$(cat "$path")"
	local re='^invocations=([0-9]+) enables=([0-9]+) ts=([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$'
	[[ "$line" =~ $re ]] || {
		echo "ERROR: stub fingerprint malformed: $path -> '$line'" >&2
		exit 1
	}
	SF_INVOC="${BASH_REMATCH[1]}"
	SF_ENABLES="${BASH_REMATCH[2]}"
	SF_TS="${BASH_REMATCH[3]}"
}

PI_GEN="$(read_pigen_sentinel "${SENTINEL_DIR}/.build-pi-gen-sha")"

RUNTIME_MANIFEST="${SENTINEL_DIR}/runtime-manifest.json"
[[ -e "$RUNTIME_MANIFEST" ]] || {
	echo "ERROR: runtime manifest missing: $RUNTIME_MANIFEST" >&2
	echo "       stage 02-install-runtime-overlay must produce this file in build mode" >&2
	exit 1
}
# Feed scripts + feeder readsb now ship through the runtime overlay (stage 02),
# not stage 01, so their SHAs come from the runtime manifest's feed_scripts /
# feed_readsb components rather than stage-01 build sentinels.
FEED_SHA="$(read_runtime_manifest_sha airplanes-feed feed_scripts "$RUNTIME_MANIFEST")"
READSB_SHA="$(read_runtime_manifest_sha airplanes-readsb feed_readsb "$RUNTIME_MANIFEST")"
DECODER_SHA="$(read_runtime_manifest_sha wiedehopf-readsb readsb_wiedehopf "$RUNTIME_MANIFEST")"
DUMP978_SHA="$(read_runtime_manifest_sha flightaware-dump978 dump978_fa "$RUNTIME_MANIFEST")"
TAR1090_SHA="$(read_runtime_manifest_sha wiedehopf-tar1090 tar1090 "$RUNTIME_MANIFEST")"
TAR1090_DB_SHA="$(read_runtime_manifest_sha wiedehopf-tar1090-db tar1090_db "$RUNTIME_MANIFEST")"
GRAPHS_SHA="$(read_runtime_manifest_sha wiedehopf-graphs1090 graphs1090 "$RUNTIME_MANIFEST")"

SF_INVOC=""; SF_ENABLES=""; SF_TS=""
parse_fingerprint "${SENTINEL_DIR}/.build-stub-fingerprint"

BUILD_TS="$(date -u +%FT%TZ)"

OUT="${SENTINEL_DIR}/build-manifest.json"
TMP="${OUT}.tmp.$$"

jq -n \
	--arg channel "$CHANNEL" \
	--arg arch "$ARCH" \
	--arg ts "$BUILD_TS" \
	--arg pi_gen "$PI_GEN" \
	--arg feed "$FEED_SHA" \
	--arg readsb "$READSB_SHA" \
	--arg decoder "$DECODER_SHA" \
	--arg dump978 "$DUMP978_SHA" \
	--arg tar1090 "$TAR1090_SHA" \
	--arg tar1090_db "$TAR1090_DB_SHA" \
	--arg graphs "$GRAPHS_SHA" \
	--argjson sf_invoc "$SF_INVOC" \
	--argjson sf_enables "$SF_ENABLES" \
	--arg sf_ts "$SF_TS" \
	'{
		schema_version: 1,
		channel: $channel,
		arch: $arch,
		build_timestamp: $ts,
		pi_gen: $pi_gen,
		components: {
			airplanes_feed:        $feed,
			airplanes_readsb:      $readsb,
			wiedehopf_readsb:      $decoder,
			wiedehopf_tar1090:     $tar1090,
			wiedehopf_tar1090_db:  $tar1090_db,
			wiedehopf_graphs1090:  $graphs,
			flightaware_dump978:   $dump978
		},
		stub_fingerprint: {
			invocations: $sf_invoc,
			enables:     $sf_enables,
			ts:          $sf_ts
		}
	}' > "$TMP"

chmod 0644 "$TMP"
mv "$TMP" "$OUT"

echo "manifest written: $OUT"
