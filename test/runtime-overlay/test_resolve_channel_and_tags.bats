#!/usr/bin/env bats

# Tests for runtime-overlay/scripts/release-workflow/resolve-channel-and-tags.sh.
# The script reads the workflow trigger context from env vars and emits
# job-output key=value pairs to $GITHUB_OUTPUT. Each case sets up the env,
# captures stdout/$GITHUB_OUTPUT, asserts the derived identity.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO_ROOT/runtime-overlay/scripts/release-workflow/resolve-channel-and-tags.sh"
    [ -x "$SCRIPT" ] || skip "resolve-channel-and-tags.sh not executable"

    export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github-output"
    : > "$GITHUB_OUTPUT"
    # Each case re-sets these. Make sure no leftover from a prior session
    # leaks through.
    unset GITHUB_EVENT_NAME GITHUB_REF GITHUB_SHA INPUT_CHANNEL INPUT_VERSION
}

@test "stable tag push: channel=stable, version from product tag" {
    export GITHUB_EVENT_NAME=push
    export GITHUB_REF=refs/tags/v1.4.0
    export GITHUB_SHA=1111111111111111111111111111111111111111

    run "$SCRIPT"
    [ "$status" -eq 0 ]

    run grep -E '^channel=stable$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    run grep -E '^version=1\.4\.0$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    run grep -E '^release_tag=v1\.4\.0$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    run grep -E '^prerelease=false$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    run grep -E '^should_publish=true$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    # A supplied (tag) version must publish verbatim — never fingerprinted.
    run grep -E '^augment_version=false$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
}

@test "dev branch push: channel=dev, release tag is dev-latest" {
    export GITHUB_EVENT_NAME=push
    export GITHUB_REF=refs/heads/dev
    export GITHUB_SHA=abcdef0123456789abcdef0123456789abcdef01

    run "$SCRIPT"
    [ "$status" -eq 0 ]

    run grep -E '^channel=dev$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    run grep -E '^release_tag=dev-latest$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    run grep -E '^prerelease=true$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    run grep -E '^version=[0-9]+\.[0-9]+\.[0-9]+-dev-[0-9]{8}-abcdef0$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    # A synthesised dev version is fingerprinted downstream.
    run grep -E '^augment_version=true$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
}

@test "workflow_dispatch stable: requires explicit version" {
    export GITHUB_EVENT_NAME=workflow_dispatch
    export GITHUB_REF=refs/heads/dev
    export GITHUB_SHA=1111111111111111111111111111111111111111
    export INPUT_CHANNEL=stable
    # INPUT_VERSION deliberately unset

    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires inputs.version"* ]]
}

@test "workflow_dispatch stable: honours INPUT_VERSION" {
    export GITHUB_EVENT_NAME=workflow_dispatch
    export GITHUB_REF=refs/heads/dev
    export GITHUB_SHA=1111111111111111111111111111111111111111
    export INPUT_CHANNEL=stable
    export INPUT_VERSION=2.0.0

    run "$SCRIPT"
    [ "$status" -eq 0 ]

    run grep -E '^channel=stable$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    run grep -E '^version=2\.0\.0$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    run grep -E '^release_tag=v2\.0\.0$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
}

@test "workflow_dispatch dev with no version: synthesises X.Y.Z-dev-YYYYMMDD-<sha7>" {
    export GITHUB_EVENT_NAME=workflow_dispatch
    export GITHUB_REF=refs/heads/dev
    export GITHUB_SHA=fedcba9876543210fedcba9876543210fedcba98
    export INPUT_CHANNEL=dev

    run "$SCRIPT"
    [ "$status" -eq 0 ]

    run grep -E '^channel=dev$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    run grep -E '^release_tag=dev-latest$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    run grep -E '^prerelease=true$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    run grep -E '^augment_version=true$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
}

@test "workflow_dispatch dev with explicit 7-hex version: verbatim, augment_version=false" {
    export GITHUB_EVENT_NAME=workflow_dispatch
    export GITHUB_REF=refs/heads/dev
    export GITHUB_SHA=1111111111111111111111111111111111111111
    export INPUT_CHANNEL=dev
    export INPUT_VERSION=1.2.3-dev-20260601-abcdef0

    run "$SCRIPT"
    [ "$status" -eq 0 ]

    # An explicit override publishes exactly as supplied. The 7-hex suffix would
    # match the helper's auto-form gate, so the resolver must signal false to
    # keep build-runtime-assets.sh from fingerprinting it.
    run grep -E '^version=1\.2\.3-dev-20260601-abcdef0$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    run grep -E '^augment_version=false$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
}

@test "main branch push: validates stable channel without publishing" {
    export GITHUB_EVENT_NAME=push
    export GITHUB_REF=refs/heads/main
    export GITHUB_SHA=2222222222222222222222222222222222222222

    run "$SCRIPT"
    [ "$status" -eq 0 ]

    run grep -E '^channel=stable$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    run grep -E '^release_tag=main-validation-2222222$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
    run grep -E '^should_publish=false$' "$GITHUB_OUTPUT"
    [ "$status" -eq 0 ]
}

@test "rejects malformed stable tag" {
    export GITHUB_EVENT_NAME=push
    export GITHUB_REF=refs/tags/v1.4
    export GITHUB_SHA=1111111111111111111111111111111111111111

    run "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "rejects unsupported push ref" {
    export GITHUB_EVENT_NAME=push
    export GITHUB_REF=refs/heads/feature
    export GITHUB_SHA=1111111111111111111111111111111111111111

    run "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "rejects non-hex GITHUB_SHA" {
    export GITHUB_EVENT_NAME=push
    export GITHUB_REF=refs/tags/v1.0.0
    export GITHUB_SHA=ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ

    run "$SCRIPT"
    [ "$status" -ne 0 ]
}
