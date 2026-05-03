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
	SHA_DECODER="cccccccccccccccccccccccccccccccccccccccc"
	SHA_DUMP978="dddddddddddddddddddddddddddddddddddddddd"
	SHA_TAR1090="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
	SHA_TAR1090_DB="ffffffffffffffffffffffffffffffffffffffff"
	SHA_GRAPHS="1234567890123456789012345678901234567890"
	SHA_PIGEN="abcdef0123456789abcdef0123456789abcdef01"
}

teardown() { rm -rf "$TMP"; }

write_sentinels() {
	printf '%s\n' "$SHA_PIGEN" > "$SENT_DIR/.build-pi-gen-sha"
	printf '%s\n' "$SHA_FEED" > "$SENT_DIR/.build-feed-sha"
	printf '%s\n' "$SHA_READSB" > "$SENT_DIR/.build-airplanes-readsb-sha"
	printf '%s\n' "$SHA_DECODER" > "$SENT_DIR/.build-readsb-decoder-sha"
	printf '%s\n' "$SHA_DUMP978" > "$SENT_DIR/.build-dump978-sha"
	printf '%s\n' "$SHA_TAR1090" > "$SENT_DIR/.build-tar1090-sha"
	printf '%s\n' "$SHA_TAR1090_DB" > "$SENT_DIR/.build-tar1090-db-sha"
	printf '%s\n' "$SHA_GRAPHS" > "$SENT_DIR/.build-graphs1090-sha"
	printf 'invocations=12 enables=3 ts=2026-05-03T19:22:30Z\n' \
		> "$SENT_DIR/.build-stub-fingerprint"
}

@test "happy path: writes manifest with all expected fields" {
	write_sentinels
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -eq 0 ]
	[ -f "$OUT" ]
	[ "$(jq -r .schema_version "$OUT")" = "1" ]
	[ "$(jq -r .channel "$OUT")" = "dev" ]
	[ "$(jq -r .arch "$OUT")" = "arm64" ]
	[ "$(jq -r .pi_gen "$OUT")" = "$SHA_PIGEN" ]
	[ "$(jq -r .components.airplanes_feed "$OUT")" = "$SHA_FEED" ]
	[ "$(jq -r .components.airplanes_readsb "$OUT")" = "$SHA_READSB" ]
	[ "$(jq -r .components.wiedehopf_readsb "$OUT")" = "$SHA_DECODER" ]
	[ "$(jq -r .components.flightaware_dump978 "$OUT")" = "$SHA_DUMP978" ]
	[ "$(jq -r .components.wiedehopf_tar1090 "$OUT")" = "$SHA_TAR1090" ]
	[ "$(jq -r .components.wiedehopf_tar1090_db "$OUT")" = "$SHA_TAR1090_DB" ]
	[ "$(jq -r .components.wiedehopf_graphs1090 "$OUT")" = "$SHA_GRAPHS" ]
	[ "$(jq -r .stub_fingerprint.invocations "$OUT")" = "12" ]
	[ "$(jq -r '.stub_fingerprint.invocations | type' "$OUT")" = "number" ]
	[ "$(jq -r .stub_fingerprint.enables "$OUT")" = "3" ]
	[ "$(jq -r '.stub_fingerprint.enables | type' "$OUT")" = "number" ]
	[ "$(jq -r .stub_fingerprint.ts "$OUT")" = "2026-05-03T19:22:30Z" ]
}

@test "manifest mode is 0644" {
	write_sentinels
	run bash -c "CHANNEL=dev ARCH=arm64 bash '$SCRIPT' '$ROOT'"
	[ "$status" -eq 0 ]
	[ "$(stat -c %a "$OUT")" = "644" ]
}

@test "build_timestamp matches ISO 8601 UTC" {
	write_sentinels
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -eq 0 ]
	ts="$(jq -r .build_timestamp "$OUT")"
	[[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "pi-gen with -dirty suffix is preserved" {
	write_sentinels
	printf '%s-dirty\n' "$SHA_PIGEN" > "$SENT_DIR/.build-pi-gen-sha"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -eq 0 ]
	[ "$(jq -r .pi_gen "$OUT")" = "$SHA_PIGEN-dirty" ]
}

@test "pi-gen 'unknown' is accepted" {
	write_sentinels
	printf 'unknown\n' > "$SENT_DIR/.build-pi-gen-sha"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -eq 0 ]
	[ "$(jq -r .pi_gen "$OUT")" = "unknown" ]
}

@test "missing pi-gen sentinel fails" {
	write_sentinels
	rm "$SENT_DIR/.build-pi-gen-sha"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
	[ ! -e "$OUT" ]
}

@test "empty SHA sentinel fails" {
	write_sentinels
	: > "$SENT_DIR/.build-feed-sha"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "non-hex sentinel content fails" {
	write_sentinels
	printf 'dev\n' > "$SENT_DIR/.build-feed-sha"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "uppercase-hex sentinel fails" {
	write_sentinels
	printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' > "$SENT_DIR/.build-feed-sha"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "short SHA sentinel fails" {
	write_sentinels
	printf 'aaaaaaa\n' > "$SENT_DIR/.build-feed-sha"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "missing CHANNEL env fails" {
	write_sentinels
	ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "missing ARCH env fails" {
	write_sentinels
	CHANNEL=dev run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "invalid CHANNEL value fails" {
	write_sentinels
	CHANNEL=prod ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "invalid ARCH value fails" {
	write_sentinels
	CHANNEL=dev ARCH=x86_64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
}

@test "malformed stub fingerprint fails" {
	write_sentinels
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
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -eq 0 ]
	if compgen -G "$SENT_DIR/build-manifest.json.tmp.*" > /dev/null; then
		echo "lingering temp file" >&2
		false
	fi
}

@test "atomic write: failure leaves no manifest" {
	write_sentinels
	# Corrupt fingerprint after sentinels written so generator fails late.
	printf 'garbage\n' > "$SENT_DIR/.build-stub-fingerprint"
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -ne 0 ]
	[ ! -e "$OUT" ]
}

@test "channel=stable arch=armhf passes" {
	write_sentinels
	CHANNEL=stable ARCH=armhf run bash "$SCRIPT" "$ROOT"
	[ "$status" -eq 0 ]
	[ "$(jq -r .channel "$OUT")" = "stable" ]
	[ "$(jq -r .arch "$OUT")" = "armhf" ]
}

@test "valid JSON output (jq parse)" {
	write_sentinels
	CHANNEL=dev ARCH=arm64 run bash "$SCRIPT" "$ROOT"
	[ "$status" -eq 0 ]
	jq -e . "$OUT" > /dev/null
}
