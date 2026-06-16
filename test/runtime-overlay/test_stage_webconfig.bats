#!/usr/bin/env bats

# Tests for runtime-overlay/scripts/lib/stage-webconfig.sh — downloads a
# webconfig release, verifies SHA256, and stages it into the overlay tree.
#
# These drive the script against a local fixture served over file:// via
# --download-base, so no network is touched. Focus is the opt-in commit-SHA
# gate: a supplied pin must match (stable), an omitted pin adopts the
# manifest's own commit_sha (dev), and a missing manifest commit_sha fails.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    STAGE="$REPO_ROOT/runtime-overlay/scripts/lib/stage-webconfig.sh"

    [ -f "$STAGE" ] || { echo "stage-webconfig.sh missing: $STAGE" >&2; return 1; }
    command -v curl     >/dev/null || skip "curl not available"
    command -v python3  >/dev/null || skip "python3 not available"
    command -v sha256sum >/dev/null || skip "sha256sum not available"

    TAG="dev-latest"
    ARCH="arm64"
    BASE="$BATS_TEST_TMPDIR/base"
    OUT="$BATS_TEST_TMPDIR/out"
    mkdir -p "$OUT"
}

# mk_fixture <commit_sha_or_empty> <version>
#
# Build a fake release under $BASE/$TAG with the four published assets. When
# the commit_sha arg is empty the manifest omits the commit_sha field entirely
# (to exercise the missing-field failure path).
mk_fixture() {
    local sha="$1" version="$2"
    local dir="$BASE/$TAG"
    mkdir -p "$dir"

    # Stub binary.
    printf 'stub-webconfig-binary\n' > "$dir/airplanes-webconfig-${ARCH}"

    # Minimal (empty) rootfs payload — a valid tarball is all stage-webconfig
    # needs; the per-file copies are all guarded by -f/-d and simply no-op.
    local empty="$BATS_TEST_TMPDIR/empty"
    mkdir -p "$empty"
    tar -czf "$dir/rootfs.tar.gz" -C "$empty" .

    # Manifest.
    if [ -n "$sha" ]; then
        printf '{"version": "%s", "commit_sha": "%s"}\n' "$version" "$sha" \
            > "$dir/manifest.json"
    else
        printf '{"version": "%s"}\n' "$version" > "$dir/manifest.json"
    fi

    # SHA256SUMS over exactly the three checked assets, bare filenames.
    ( cd "$dir" && sha256sum \
        "airplanes-webconfig-${ARCH}" rootfs.tar.gz manifest.json \
        > SHA256SUMS )
}

run_stage() {
    run "$STAGE" \
        --release-tag "$TAG" \
        --arch "$ARCH" \
        --output-dir "$OUT" \
        --download-base "file://$BASE" \
        "$@"
}

@test "no --commit-sha: succeeds and records the manifest commit_sha" {
    local sha="abcabcabcabcabcabcabcabcabcabcabcabcabca"
    mk_fixture "$sha" "1.2.3"

    run_stage
    [ "$status" -eq 0 ]

    [ -f "$OUT/components.webconfig.sha" ]
    [ "$(cat "$OUT/components.webconfig.sha")" = "$sha" ]
    [ "$(cat "$OUT/components.webconfig.version")" = "1.2.3" ]
    [ -f "$OUT/bin/airplanes-webconfig" ]
}

@test "pinned --commit-sha matching the manifest: succeeds" {
    local sha="0123456789abcdef0123456789abcdef01234567"
    mk_fixture "$sha" "2.0.0"

    run_stage --commit-sha "$sha"
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/components.webconfig.sha")" = "$sha" ]
}

@test "pinned --commit-sha mismatching the manifest: fails" {
    mk_fixture "1111111111111111111111111111111111111111" "2.0.0"

    run_stage --commit-sha "2222222222222222222222222222222222222222"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not match expected"* ]]
}

@test "manifest missing commit_sha: fails even without a pin" {
    mk_fixture "" "3.0.0"

    run_stage
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing commit_sha"* ]]
}

@test "malformed --commit-sha (not 40-hex): fails fast" {
    mk_fixture "4444444444444444444444444444444444444444" "1.0.0"

    run_stage --commit-sha "not-a-sha"
    [ "$status" -ne 0 ]
    [[ "$output" == *"40 lowercase hex"* ]]
}

@test "populated rootfs: stages apl-aggregator helper, unit, run-helper, descriptors" {
    # The other tests use an empty rootfs so the per-file copies no-op. This one
    # carries the webconfig-owned aggregator artifacts and asserts they land in
    # the overlay tree (helper binary, run-helper, adapter descriptors dir, and
    # the systemd template) — the files managed_paths then symlinks onto the image.
    local sha="abcabcabcabcabcabcabcabcabcabcabcabcabca"
    local dir="$BASE/$TAG"
    mkdir -p "$dir"
    printf 'stub-webconfig-binary\n' > "$dir/airplanes-webconfig-${ARCH}"

    local rfs="$BATS_TEST_TMPDIR/rootfs-pop"
    mkdir -p "$rfs/usr/local/bin" \
             "$rfs/usr/local/lib/airplanes-webconfig/aggregators" \
             "$rfs/etc/systemd/system"
    printf '#!/usr/bin/env bash\n' > "$rfs/usr/local/bin/apl-aggregator"
    printf '#!/usr/bin/env bash\n' > "$rfs/usr/local/bin/apl-wifi"
    printf '#!/usr/bin/env bash\n' > "$rfs/usr/local/lib/airplanes-webconfig/aggregator-run"
    printf 'id=fr24\n'             > "$rfs/usr/local/lib/airplanes-webconfig/aggregators/fr24.desc"
    printf '[Unit]\n'             > "$rfs/etc/systemd/system/airplanes-aggregator@.service"
    printf '[Unit]\n'             > "$rfs/etc/systemd/system/airplanes-webconfig.service"
    tar -czf "$dir/rootfs.tar.gz" -C "$rfs" .

    printf '{"version": "9.9.9", "commit_sha": "%s"}\n' "$sha" > "$dir/manifest.json"
    ( cd "$dir" && sha256sum "airplanes-webconfig-${ARCH}" rootfs.tar.gz manifest.json > SHA256SUMS )

    run_stage
    [ "$status" -eq 0 ]
    [ -f "$OUT/bin/apl-aggregator" ]
    [ -f "$OUT/lib/airplanes-webconfig/aggregator-run" ]
    [ -f "$OUT/lib/airplanes-webconfig/aggregators/fr24.desc" ]
    [ -f "$OUT/systemd/airplanes-aggregator@.service" ]
}

@test "malformed manifest commit_sha (not 40-hex): fails even without a pin" {
    local dir="$BASE/$TAG"
    mkdir -p "$dir"
    printf 'stub\n' > "$dir/airplanes-webconfig-${ARCH}"
    local empty="$BATS_TEST_TMPDIR/empty2"
    mkdir -p "$empty"
    tar -czf "$dir/rootfs.tar.gz" -C "$empty" .
    printf '{"version": "1.0.0", "commit_sha": "not-a-real-sha"}\n' > "$dir/manifest.json"
    ( cd "$dir" && sha256sum "airplanes-webconfig-${ARCH}" rootfs.tar.gz manifest.json > SHA256SUMS )

    run_stage
    [ "$status" -ne 0 ]
    [[ "$output" == *"40 lowercase hex"* ]]
}

# Install a PATH-shim `curl` that fails fetches whose URL ends in <suffix> for
# the first <times> invocations (counted in $FAIL_COUNTER), then delegates to
# the real curl. Simulates an asset briefly 404ing while dev-latest republishes.
install_flaky_curl() {
    local suffix="$1" times="$2"
    local shimdir="$BATS_TEST_TMPDIR/shim"
    mkdir -p "$shimdir"
    REAL_CURL="$(command -v curl)"
    FAIL_SUFFIX="$suffix"
    FAIL_TIMES="$times"
    FAIL_COUNTER="$BATS_TEST_TMPDIR/curlfail.count"
    : > "$FAIL_COUNTER"
    cat > "$shimdir/curl" <<'SHIM'
#!/usr/bin/env bash
url="${@: -1}"
if [[ "$url" == *"$FAIL_SUFFIX" ]]; then
    n=0; [ -s "$FAIL_COUNTER" ] && n="$(cat "$FAIL_COUNTER")"
    n=$((n + 1)); printf '%s' "$n" > "$FAIL_COUNTER"
    if [ "$n" -le "$FAIL_TIMES" ]; then
        echo "fake curl: simulated transient failure $n for $url" >&2
        exit 22
    fi
fi
exec "$REAL_CURL" "$@"
SHIM
    chmod +x "$shimdir/curl"
    export PATH="$shimdir:$PATH"
    export REAL_CURL FAIL_SUFFIX FAIL_TIMES FAIL_COUNTER
    export STAGE_WEBCONFIG_DL_BACKOFF=0
}

@test "transient asset failure during republish: retries then succeeds" {
    local sha="abcabcabcabcabcabcabcabcabcabcabcabcabca"
    mk_fixture "$sha" "1.2.3"
    install_flaky_curl "manifest.json" 2
    export STAGE_WEBCONFIG_DL_ATTEMPTS=5

    run_stage
    [ "$status" -eq 0 ]
    [ "$(cat "$FAIL_COUNTER")" = "3" ]   # 2 transient failures + 1 success
    [[ "$output" == *"retrying"* ]]
    [ "$(cat "$OUT/components.webconfig.sha")" = "$sha" ]
}

@test "persistent asset failure: dies after the attempt budget" {
    mk_fixture "abcabcabcabcabcabcabcabcabcabcabcabcabca" "1.2.3"
    install_flaky_curl "manifest.json" 999
    export STAGE_WEBCONFIG_DL_ATTEMPTS=3

    run_stage
    [ "$status" -ne 0 ]
    [[ "$output" == *"after 3 attempts"* ]]
    [ "$(cat "$FAIL_COUNTER")" = "3" ]   # exactly the budget, no extra attempts
}

@test "invalid attempt budget is rejected before any download" {
    mk_fixture "abcabcabcabcabcabcabcabcabcabcabcabcabca" "1.2.3"
    export STAGE_WEBCONFIG_DL_ATTEMPTS=08   # would loop forever in arithmetic without the guard

    run_stage
    [ "$status" -ne 0 ]
    [[ "$output" == *"must be a positive integer"* ]]
}
