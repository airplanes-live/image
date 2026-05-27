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
