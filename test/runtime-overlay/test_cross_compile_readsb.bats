#!/usr/bin/env bats

# Tests for runtime-overlay/scripts/lib/cross-compile-readsb.sh — clones the
# wiedehopf readsb fork and cross-compiles for arm64.
#
# The full-build paths skip on non-arm64 hosts (cross-compile is not
# configured here; CI runs the arm64 path on ubuntu-24.04-arm). Argument
# validation and arch-rejection paths run everywhere — they don't invoke
# `make`. Network-requiring tests gate on RUN_NETWORK_TESTS=1 so offline
# CI doesn't fail.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HELPER="$REPO_ROOT/runtime-overlay/scripts/lib/cross-compile-readsb.sh"
    [ -x "$HELPER" ] || skip "cross-compile-readsb.sh not executable: $HELPER"

    OUTPUT_DIR="$BATS_TEST_TMPDIR/out"
    install -d -m 0755 "$OUTPUT_DIR"

    HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
}

@test "rejects --arch armhf" {
    run "$HELPER" \
        --repo https://example.invalid/repo.git \
        --ref dev \
        --arch armhf \
        --output-dir "$OUTPUT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"armhf"* ]]
}

@test "rejects an unknown --arch" {
    run "$HELPER" \
        --repo https://example.invalid/repo.git \
        --ref dev \
        --arch x86_64 \
        --output-dir "$OUTPUT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"arm64"* ]]
}

@test "rejects a missing required argument" {
    run "$HELPER" \
        --ref dev \
        --arch arm64 \
        --output-dir "$OUTPUT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"repo"* ]]
}

@test "rejects an unknown argument" {
    run "$HELPER" --bogus value
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown argument"* ]]
}

# The build path is exercised only on arm64 hosts and only when the caller
# opts into network access. On amd64 the helper rejects the call before
# touching the network — the rejection-path covers this from the host side
# of the cross-compile boundary.
@test "rejects cross-compile on non-arm64 host" {
    if [ "$HOST_ARCH" == "arm64" ]; then
        skip "host arch is arm64; this test covers the cross-compile-rejection path"
    fi
    if [ -z "${RUN_NETWORK_TESTS:-}" ]; then
        skip "set RUN_NETWORK_TESTS=1 to exercise this path (requires network)"
    fi
    # Use a small public repo for the clone — any valid git ref will do
    # because the helper bails before invoking make.
    run "$HELPER" \
        --repo https://github.com/wiedehopf/readsb.git \
        --ref dev \
        --arch arm64 \
        --output-dir "$OUTPUT_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"arm64 host"* ]] || [[ "$output" == *"cross-compile"* ]]
}

@test "builds readsb and records component pin (arm64 host only, gated)" {
    if [ "$HOST_ARCH" != "arm64" ]; then
        skip "arm64-only build (host arch: $HOST_ARCH)"
    fi
    if [ -z "${RUN_NETWORK_TESTS:-}" ]; then
        skip "set RUN_NETWORK_TESTS=1 to exercise this path (requires network + build deps)"
    fi

    run "$HELPER" \
        --repo https://github.com/wiedehopf/readsb.git \
        --ref dev \
        --arch arm64 \
        --output-dir "$OUTPUT_DIR"
    [ "$status" -eq 0 ]
    [ -x "$OUTPUT_DIR/bin/readsb" ]
    [ -s "$OUTPUT_DIR/components.readsb_wiedehopf.sha" ]

    # Pin must be a 40-hex SHA.
    sha="$(cat "$OUTPUT_DIR/components.readsb_wiedehopf.sha")"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]]

    # ldd-clean check.
    run ldd "$OUTPUT_DIR/bin/readsb"
    [ "$status" -eq 0 ]
    [[ "$output" != *"not found"* ]]
}
