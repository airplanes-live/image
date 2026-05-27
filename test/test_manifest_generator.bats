#!/usr/bin/env bats

setup() {
	REPO_ROOT="$BATS_TEST_DIRNAME/.."
	SCRIPT="$REPO_ROOT/scripts/manifest-generator.sh"
	TMP="$(mktemp -d)"
	ROOT="$TMP/r"
	SENT_DIR="$ROOT/etc/airplanes"
	OUT="$SENT_DIR/build-manifest.json"
	mkdir -p "$SENT_DIR"

	# Distinct SHAs per slot so a field swap shows up in the JSON.
	SHA_FEED="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	SHA_READSB="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	SHA_PIGEN="abcdef0123456789abcdef0123456789abcdef01"
	SHA_RUNTIME_DECODER="1111111111111111111111111111111111111111"
	SHA_RUNTIME_DUMP978="2222222222222222222222222222222222222222"
	SHA_RUNTIME_TAR1090="3333333333333333333333333333333333333333"
	SHA_RUNTIME_TAR1090_DB="4444444444444444444444444444444444444444"
	SHA_RUNTIME_GRAPHS="5555555555555555555555555555555555555555"
}

teardown() { rm -rf "$TMP"; }

# Feed scripts + feeder readsb now ship through the runtime overlay, so their
# SHAs live in the runtime manifest's feed_scripts / feed_readsb components.
# Only the pi-gen + stub-fingerprint sentinels remain stage-side.
write_sentinels() {
	printf '%s\n' "$SHA_PIGEN" > "$SENT_DIR/.build-pi-gen-sha"
	printf 'invocations=12 enables=3 ts=2026-05-03T19:22:30Z\n' \
		> "$SENT_DIR/.build-stub-fingerprint"
}

write_runtime_manifest() {
	jq -n \
		--arg feed "$SHA_FEED" \
		--arg readsb "$SHA_READSB" \
		--arg decoder "$SHA_RUNTIME_DECODER" \
		--arg dump978 "$SHA_RUNTIME_DUMP978" \
		--arg tar1090 "$SHA_RUNTIME_TAR1090" \
		--arg tar1090_db "$SHA_RUNTIME_TAR1090_DB" \
		--arg graphs "$SHA_RUNTIME_GRAPHS" \
		'{
			components: {
				feed_scripts: $feed,
				feed_readsb: $readsb,
				readsb_wiedehopf: $decoder,
				dump978_fa: $dump978,
				tar1090: $tar1090,
				tar1090_db: $tar1090_db,
				graphs1090: $graphs
			}
		}' > "$SENT_DIR/runtime-manifest.json"
}

@test "happy path: writes manifest with all expected fields" {
	write_sentinels
	write_runtime_manifest
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -eq 0 ]
	[ -f "$OUT" ]
	[ "$(jq -r .schema_version "$OUT")" = "1" ]
	[ "$(jq -r .channel "$OUT")" = "dev" ]
	[ "$(jq -r .arch "$OUT")" = "arm64" ]
	[ "$(jq -r .pi_gen "$OUT")" = "$SHA_PIGEN" ]
	[ "$(jq -r .components.airplanes_feed "$OUT")" = "$SHA_FEED" ]
	[ "$(jq -r .components.airplanes_readsb "$OUT")" = "$SHA_READSB" ]
	[ "$(jq -r .components.wiedehopf_readsb "$OUT")" = "$SHA_RUNTIME_DECODER" ]
	[ "$(jq -r .components.flightaware_dump978 "$OUT")" = "$SHA_RUNTIME_DUMP978" ]
	[ "$(jq -r .components.wiedehopf_tar1090 "$OUT")" = "$SHA_RUNTIME_TAR1090" ]
	[ "$(jq -r .components.wiedehopf_tar1090_db "$OUT")" = "$SHA_RUNTIME_TAR1090_DB" ]
	[ "$(jq -r .components.wiedehopf_graphs1090 "$OUT")" = "$SHA_RUNTIME_GRAPHS" ]
	[ "$(jq -r .stub_fingerprint.invocations "$OUT")" = "12" ]
	[ "$(jq -r '.stub_fingerprint.invocations | type' "$OUT")" = "number" ]
	[ "$(jq -r .stub_fingerprint.enables "$OUT")" = "3" ]
	[ "$(jq -r '.stub_fingerprint.enables | type' "$OUT")" = "number" ]
	[ "$(jq -r .stub_fingerprint.ts "$OUT")" = "2026-05-03T19:22:30Z" ]
}

@test "runtime manifest accepts component objects with commit_sha" {
	write_sentinels
	jq -n \
		--arg feed "$SHA_FEED" \
		--arg readsb "$SHA_READSB" \
		--arg decoder "$SHA_RUNTIME_DECODER" \
		--arg dump978 "$SHA_RUNTIME_DUMP978" \
		--arg tar1090 "$SHA_RUNTIME_TAR1090" \
		--arg tar1090_db "$SHA_RUNTIME_TAR1090_DB" \
		--arg graphs "$SHA_RUNTIME_GRAPHS" \
		'{
			components: {
				feed_scripts: {commit_sha: $feed},
				feed_readsb: {commit_sha: $readsb},
				readsb_wiedehopf: {commit_sha: $decoder},
				dump978_fa: {commit_sha: $dump978},
				tar1090: {commit_sha: $tar1090},
				tar1090_db: {commit_sha: $tar1090_db},
				graphs1090: {commit_sha: $graphs}
			}
		}' > "$SENT_DIR/runtime-manifest.json"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -eq 0 ]
	[ "$(jq -r .components.airplanes_feed "$OUT")" = "$SHA_FEED" ]
	[ "$(jq -r .components.airplanes_readsb "$OUT")" = "$SHA_READSB" ]
	[ "$(jq -r .components.wiedehopf_readsb "$OUT")" = "$SHA_RUNTIME_DECODER" ]
	[ "$(jq -r .components.flightaware_dump978 "$OUT")" = "$SHA_RUNTIME_DUMP978" ]
	[ "$(jq -r .components.wiedehopf_tar1090 "$OUT")" = "$SHA_RUNTIME_TAR1090" ]
	[ "$(jq -r .components.wiedehopf_tar1090_db "$OUT")" = "$SHA_RUNTIME_TAR1090_DB" ]
	[ "$(jq -r .components.wiedehopf_graphs1090 "$OUT")" = "$SHA_RUNTIME_GRAPHS" ]
}

@test "missing runtime manifest fails" {
	write_sentinels
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
	[ ! -e "$OUT" ]
	[[ "$output" == *"runtime manifest missing"* ]]
}

@test "runtime manifest missing component fails" {
	write_sentinels
	# Manifest present but missing one of the required components (graphs1090).
	jq -n \
		--arg feed "$SHA_FEED" \
		--arg readsb "$SHA_READSB" \
		--arg decoder "$SHA_RUNTIME_DECODER" \
		--arg dump978 "$SHA_RUNTIME_DUMP978" \
		--arg tar1090 "$SHA_RUNTIME_TAR1090" \
		--arg tar1090_db "$SHA_RUNTIME_TAR1090_DB" \
		'{
			components: {
				feed_scripts: $feed,
				feed_readsb: $readsb,
				readsb_wiedehopf: $decoder,
				dump978_fa: $dump978,
				tar1090: $tar1090,
				tar1090_db: $tar1090_db
			}
		}' > "$SENT_DIR/runtime-manifest.json"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
	[ ! -e "$OUT" ]
}

@test "manifest mode is 0644" {
	write_sentinels
	write_runtime_manifest
	run bash -c "CHANNEL=dev ARCH=arm64 bash '$SCRIPT' '$ROOT'"
	[ "$status" -eq 0 ]
	[ "$(stat -c %a "$OUT")" = "644" ]
}

@test "build_timestamp matches ISO 8601 UTC" {
	write_sentinels
	write_runtime_manifest
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -eq 0 ]
	ts="$(jq -r .build_timestamp "$OUT")"
	[[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "pi-gen with -dirty suffix is preserved" {
	write_sentinels
	write_runtime_manifest
	printf '%s-dirty\n' "$SHA_PIGEN" > "$SENT_DIR/.build-pi-gen-sha"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -eq 0 ]
	[ "$(jq -r .pi_gen "$OUT")" = "$SHA_PIGEN-dirty" ]
}

@test "pi-gen 'unknown' is accepted" {
	write_sentinels
	write_runtime_manifest
	printf 'unknown\n' > "$SENT_DIR/.build-pi-gen-sha"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -eq 0 ]
	[ "$(jq -r .pi_gen "$OUT")" = "unknown" ]
}

@test "missing pi-gen sentinel fails" {
	write_sentinels
	write_runtime_manifest
	rm "$SENT_DIR/.build-pi-gen-sha"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
	[ ! -e "$OUT" ]
}

@test "missing feed_scripts component fails" {
	write_sentinels
	write_runtime_manifest
	# Drop feed_scripts from the runtime manifest — the generator now sources
	# the feed SHA from there, so its absence must fail.
	jq 'del(.components.feed_scripts)' "$SENT_DIR/runtime-manifest.json" \
		> "$SENT_DIR/runtime-manifest.json.tmp"
	mv "$SENT_DIR/runtime-manifest.json.tmp" "$SENT_DIR/runtime-manifest.json"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "non-hex feed_scripts component fails" {
	write_sentinels
	write_runtime_manifest
	jq '.components.feed_scripts = "dev"' "$SENT_DIR/runtime-manifest.json" \
		> "$SENT_DIR/runtime-manifest.json.tmp"
	mv "$SENT_DIR/runtime-manifest.json.tmp" "$SENT_DIR/runtime-manifest.json"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "uppercase-hex feed_readsb component fails" {
	write_sentinels
	write_runtime_manifest
	jq '.components.feed_readsb = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' \
		"$SENT_DIR/runtime-manifest.json" > "$SENT_DIR/runtime-manifest.json.tmp"
	mv "$SENT_DIR/runtime-manifest.json.tmp" "$SENT_DIR/runtime-manifest.json"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "short feed_scripts component fails" {
	write_sentinels
	write_runtime_manifest
	jq '.components.feed_scripts = "aaaaaaa"' "$SENT_DIR/runtime-manifest.json" \
		> "$SENT_DIR/runtime-manifest.json.tmp"
	mv "$SENT_DIR/runtime-manifest.json.tmp" "$SENT_DIR/runtime-manifest.json"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "missing CHANNEL env fails" {
	write_sentinels
	write_runtime_manifest
	ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "missing ARCH env fails" {
	write_sentinels
	write_runtime_manifest
	CHANNEL=dev run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "invalid CHANNEL value fails" {
	write_sentinels
	write_runtime_manifest
	CHANNEL=prod ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "invalid ARCH value fails" {
	write_sentinels
	write_runtime_manifest
	CHANNEL=dev ARCH=x86_64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "malformed stub fingerprint fails" {
	write_sentinels
	write_runtime_manifest
	printf 'invocations=12\n' > "$SENT_DIR/.build-stub-fingerprint"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "ROOTFS_DIR argument missing fails" {
	run bash "$SCRIPT"
	[ "$status" -ne 0 ]
}

@test "atomic write: no lingering temp file on success" {
	write_sentinels
	write_runtime_manifest
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -eq 0 ]
	if compgen -G "$SENT_DIR/build-manifest.json.tmp.*" > /dev/null; then
		echo "lingering temp file" >&2
		false
	fi
}

@test "atomic write: failure leaves no manifest" {
	write_sentinels
	write_runtime_manifest
	# Corrupt fingerprint after sentinels written so generator fails late.
	printf 'garbage\n' > "$SENT_DIR/.build-stub-fingerprint"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
	[ ! -e "$OUT" ]
}

@test "channel=stable arch=armhf passes" {
	write_sentinels
	write_runtime_manifest
	CHANNEL=stable ARCH=armhf run bash "$SCRIPT" "$ROOT"
	[ "$status" -eq 0 ]
	[ "$(jq -r .channel "$OUT")" = "stable" ]
	[ "$(jq -r .arch "$OUT")" = "armhf" ]
}

@test "valid JSON output (jq parse)" {
	write_sentinels
	write_runtime_manifest
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -eq 0 ]
	jq -e . "$OUT" > /dev/null
}
