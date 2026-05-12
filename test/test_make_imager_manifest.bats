#!/usr/bin/env bats

# Tests for scripts/make-imager-manifest.sh. The script generates the
# .rpi-imager-manifest.json sidecar that rpi-imager reads as a Custom
# Repository. These tests focus on the optional --commit-sha / --build-time
# identity flags (which add a disambiguator suffix to the OS-list name and a
# trailing sentence to the description for same-day dev-build identification)
# and on the validation invariants that protect a previously valid manifest
# from being deleted by an invalid-flag call.

setup() {
	REPO_ROOT="$BATS_TEST_DIRNAME/.."
	SCRIPT="$REPO_ROOT/scripts/make-imager-manifest.sh"
	TMP="$(mktemp -d)"
	IMG="$TMP/airplanes-feeder-dev-arm64.img.xz"
	OUT="${IMG%.img.xz}.rpi-imager-manifest.json"
	# Synthetic .img.xz — the script only invokes xz --robot --list,
	# xz -dc | sha256sum, and stat on it.
	head -c 4096 /dev/urandom | xz -z > "$IMG"

	SHA40="1064ad4a23f9b1e3aabbccddeeff001122334455"
	SHA12="1064ad4a23f9"
	BTIME="2026-05-12T14:32:08Z"
}

teardown() { rm -rf "$TMP"; }

# ---- happy path: both flags --------------------------------------------------

@test "name and description include sha + time when both flags are passed" {
	run bash "$SCRIPT" --commit-sha "$SHA40" --build-time "$BTIME" "$IMG"
	[ "$status" -eq 0 ]
	[ -f "$OUT" ]
	name="$(jq -r .os_list[0].name "$OUT")"
	desc="$(jq -r .os_list[0].description "$OUT")"
	[ "$name" = "airplanes.live feeder (dev) · ${SHA12} · 14:32Z" ]
	[[ "$desc" == *"Build ${SHA12} @ 2026-05-12 14:32:08 UTC."* ]]
}

@test "--commit-sha=value and --build-time=value form is accepted" {
	run bash "$SCRIPT" "--commit-sha=$SHA40" "--build-time=$BTIME" "$IMG"
	[ "$status" -eq 0 ]
	name="$(jq -r .os_list[0].name "$OUT")"
	[ "$name" = "airplanes.live feeder (dev) · ${SHA12} · 14:32Z" ]
}

@test "minimum-length (7-char) --commit-sha is accepted and slices to the same 7" {
	run bash "$SCRIPT" --commit-sha "1064ad4" --build-time "$BTIME" "$IMG"
	[ "$status" -eq 0 ]
	name="$(jq -r .os_list[0].name "$OUT")"
	[ "$name" = "airplanes.live feeder (dev) · 1064ad4 · 14:32Z" ]
}

@test "stable filename produces 'stable' channel name and description" {
	STABLE_IMG="$TMP/airplanes-feeder-stable-arm64.img.xz"
	STABLE_OUT="${STABLE_IMG%.img.xz}.rpi-imager-manifest.json"
	head -c 4096 /dev/urandom | xz -z > "$STABLE_IMG"
	run bash "$SCRIPT" --commit-sha "$SHA40" --build-time "$BTIME" "$STABLE_IMG"
	[ "$status" -eq 0 ]
	name="$(jq -r .os_list[0].name "$STABLE_OUT")"
	desc="$(jq -r .os_list[0].description "$STABLE_OUT")"
	[ "$name" = "airplanes.live feeder (stable) · ${SHA12} · 14:32Z" ]
	[[ "$desc" == *"(stable channel)"* ]]
	[[ "$desc" == *"Build ${SHA12} @ 2026-05-12 14:32:08 UTC."* ]]
}

# ---- back-compat: no flags ---------------------------------------------------

@test "no flags: name and description match current literals exactly" {
	run bash "$SCRIPT" "$IMG"
	[ "$status" -eq 0 ]
	name="$(jq -r .os_list[0].name "$OUT")"
	desc="$(jq -r .os_list[0].description "$OUT")"
	[ "$name" = "airplanes.live feeder (dev)" ]
	[ "$desc" = "airplanes.live ADS-B/MLAT/UAT feeder image (dev channel). Use Edit Settings to set hostname, WiFi, and SSH access before flashing. Receiver location and MLAT name are configured after first boot via the web UI." ]
}

@test "no flags + GIT_HASH env: env must NOT leak into output" {
	GIT_HASH="$SHA40" run bash "$SCRIPT" "$IMG"
	[ "$status" -eq 0 ]
	name="$(jq -r .os_list[0].name "$OUT")"
	desc="$(jq -r .os_list[0].description "$OUT")"
	[ "$name" = "airplanes.live feeder (dev)" ]
	[[ "$name" != *"$SHA12"* ]]
	[[ "$desc" != *"$SHA12"* ]]
}

# ---- validation: half-set ---------------------------------------------------

@test "only --commit-sha (no --build-time) fails" {
	run bash "$SCRIPT" --commit-sha "$SHA40" "$IMG"
	[ "$status" -eq 2 ]
	[ ! -e "$OUT" ]
	[[ "$output" == *"must be passed together"* ]]
}

@test "only --build-time (no --commit-sha) fails" {
	run bash "$SCRIPT" --build-time "$BTIME" "$IMG"
	[ "$status" -eq 2 ]
	[ ! -e "$OUT" ]
	[[ "$output" == *"must be passed together"* ]]
}

# ---- validation: commit-sha shape ------------------------------------------

@test "non-hex --commit-sha fails" {
	run bash "$SCRIPT" --commit-sha "deadbeefnotvalidhex0" --build-time "$BTIME" "$IMG"
	[ "$status" -eq 2 ]
	[ ! -e "$OUT" ]
	[[ "$output" == *"7-40 lowercase hex"* ]]
}

@test "short (<7) --commit-sha fails" {
	run bash "$SCRIPT" --commit-sha "abc123" --build-time "$BTIME" "$IMG"
	[ "$status" -eq 2 ]
	[ ! -e "$OUT" ]
}

@test "uppercase --commit-sha fails" {
	run bash "$SCRIPT" --commit-sha "ABCDEF1234567" --build-time "$BTIME" "$IMG"
	[ "$status" -eq 2 ]
	[ ! -e "$OUT" ]
}

# ---- validation: build-time shape -------------------------------------------

@test "--build-time without seconds fails (HH:MMZ)" {
	run bash "$SCRIPT" --commit-sha "$SHA40" --build-time "2026-05-12T14:32Z" "$IMG"
	[ "$status" -eq 2 ]
	[ ! -e "$OUT" ]
}

@test "--build-time without trailing Z fails" {
	run bash "$SCRIPT" --commit-sha "$SHA40" --build-time "2026-05-12T14:32:08" "$IMG"
	[ "$status" -eq 2 ]
	[ ! -e "$OUT" ]
}

@test "--build-time with timezone offset fails (only Z accepted)" {
	run bash "$SCRIPT" --commit-sha "$SHA40" --build-time "2026-05-12T14:32:08+00:00" "$IMG"
	[ "$status" -eq 2 ]
	[ ! -e "$OUT" ]
}

@test "--build-time relative string fails" {
	run bash "$SCRIPT" --commit-sha "$SHA40" --build-time "yesterday" "$IMG"
	[ "$status" -eq 2 ]
	[ ! -e "$OUT" ]
}

@test "--build-time impossible date fails (Feb 30)" {
	run bash "$SCRIPT" --commit-sha "$SHA40" --build-time "2026-02-30T00:00:00Z" "$IMG"
	[ "$status" -eq 2 ]
	[ ! -e "$OUT" ]
}

# ---- validate-before-rm: prior manifest survives invalid-flag call ----------

@test "invalid --commit-sha does not delete a pre-existing manifest" {
	printf '{"sentinel":true}\n' > "$OUT"
	run bash "$SCRIPT" --commit-sha "not-hex" --build-time "$BTIME" "$IMG"
	[ "$status" -ne 0 ]
	[ -f "$OUT" ]
	[ "$(jq -r .sentinel "$OUT")" = "true" ]
}

@test "invalid --build-time does not delete a pre-existing manifest" {
	printf '{"sentinel":true}\n' > "$OUT"
	run bash "$SCRIPT" --commit-sha "$SHA40" --build-time "tomorrow" "$IMG"
	[ "$status" -ne 0 ]
	[ -f "$OUT" ]
	[ "$(jq -r .sentinel "$OUT")" = "true" ]
}

@test "half-set flags do not delete a pre-existing manifest" {
	printf '{"sentinel":true}\n' > "$OUT"
	run bash "$SCRIPT" --commit-sha "$SHA40" "$IMG"
	[ "$status" -ne 0 ]
	[ -f "$OUT" ]
	[ "$(jq -r .sentinel "$OUT")" = "true" ]
}

# ---- atomic write ------------------------------------------------------------

@test "happy path leaves no .tmp.* sidecar files" {
	run bash "$SCRIPT" --commit-sha "$SHA40" --build-time "$BTIME" "$IMG"
	[ "$status" -eq 0 ]
	if compgen -G "${OUT}.tmp.*" > /dev/null; then
		echo "lingering temp file" >&2
		false
	fi
}

# ---- schema unchanged -------------------------------------------------------

@test "all existing manifest fields still present and correctly typed" {
	run bash "$SCRIPT" --commit-sha "$SHA40" --build-time "$BTIME" "$IMG"
	[ "$status" -eq 0 ]
	# jq -e fails the test if the predicate evaluates to false/null.
	jq -e '
		(.imager.devices | type == "array" and length > 0)
		and (.imager.devices[0]
			| has("name") and has("tags") and has("icon")
			and has("description") and has("matching_type")
			and has("capabilities"))
	' "$OUT" > /dev/null
	jq -e '
		(.os_list | type == "array" and length == 1)
		and (.os_list[0]
			| (.name | type == "string")
			and (.description | type == "string")
			and (.icon | type == "string")
			and (.release_date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
			and (.init_format == "cloudinit-rpi")
			and (.url | type == "string")
			and (.extract_size | type == "number")
			and (.extract_sha256 | test("^[0-9a-f]{64}$"))
			and (.image_download_size | type == "number")
			and (.devices | type == "array")
			and (.capabilities | type == "array"))
	' "$OUT" > /dev/null
}
