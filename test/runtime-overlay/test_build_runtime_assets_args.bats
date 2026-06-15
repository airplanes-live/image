#!/usr/bin/env bats

# Argument-validation tests for
# runtime-overlay/scripts/release-workflow/build-runtime-assets.sh.
#
# These exercise only the early validation block, which runs before any config
# sourcing, cross-compilation, or staging — so they are fast and need no build
# toolchain. The orchestrator's full happy path is covered by the image-build
# workflow, not here.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO_ROOT/runtime-overlay/scripts/release-workflow/build-runtime-assets.sh"
    [ -x "$SCRIPT" ] || skip "build-runtime-assets.sh not executable: $SCRIPT"
    SHA40="1111111111111111111111111111111111111111"
}

@test "rejects a non-boolean --augment-dev-version before doing any work" {
    run bash "$SCRIPT" \
        --channel dev \
        --version "0.0.0-dev-20260101-abcdef0" \
        --commit-sha "$SHA40" \
        --arch arm64 \
        --output-dir "$BATS_TEST_TMPDIR/out" \
        --augment-dev-version bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"augment-dev-version must be true or false"* ]]
    # Validation must fire before the output dir is created.
    [ ! -d "$BATS_TEST_TMPDIR/out" ]
}

@test "rejects an empty --augment-dev-version (broken workflow output mapping)" {
    run bash "$SCRIPT" \
        --channel dev \
        --version "0.0.0-dev-20260101-abcdef0" \
        --commit-sha "$SHA40" \
        --arch arm64 \
        --output-dir "$BATS_TEST_TMPDIR/out" \
        --augment-dev-version ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"augment-dev-version must be true or false"* ]]
}
