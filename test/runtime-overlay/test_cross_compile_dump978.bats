#!/usr/bin/env bats

# Tests for runtime-overlay/scripts/lib/cross-compile-dump978.sh — clones
# flightaware's dump978 and builds the dump978-fa target for arm64.
#
# Same skip-policy as test_cross_compile_readsb.bats: validation/error
# paths run everywhere; the full build path requires arm64 + network.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HELPER="$REPO_ROOT/runtime-overlay/scripts/lib/cross-compile-dump978.sh"
    [ -x "$HELPER" ] || skip "cross-compile-dump978.sh not executable: $HELPER"

    OUTPUT_DIR="$BATS_TEST_TMPDIR/out"
    install -d -m 0755 "$OUTPUT_DIR"

    HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
}

@test "rejects --arch armhf" {
    run "$HELPER" \
        --repo https://example.invalid/repo.git \
        --ref master \
        --arch armhf \
        --output-dir "$OUTPUT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"armhf"* ]]
}

@test "rejects a missing required argument" {
    run "$HELPER" \
        --repo https://example.invalid/repo.git \
        --arch arm64 \
        --output-dir "$OUTPUT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ref"* ]]
}

@test "builds dump978-fa and records component pin (arm64 host only, gated)" {
    if [ "$HOST_ARCH" != "arm64" ]; then
        skip "arm64-only build (host arch: $HOST_ARCH)"
    fi
    if [ -z "${RUN_NETWORK_TESTS:-}" ]; then
        skip "set RUN_NETWORK_TESTS=1 to exercise this path"
    fi

    run "$HELPER" \
        --repo https://github.com/flightaware/dump978.git \
        --ref master \
        --arch arm64 \
        --output-dir "$OUTPUT_DIR"
    [ "$status" -eq 0 ]
    [ -x "$OUTPUT_DIR/bin/dump978-fa" ]
    [ -s "$OUTPUT_DIR/components.dump978_fa.sha" ]

    sha="$(cat "$OUTPUT_DIR/components.dump978_fa.sha")"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]]

    run ldd "$OUTPUT_DIR/bin/dump978-fa"
    [ "$status" -eq 0 ]
    [[ "$output" != *"not found"* ]]
}
