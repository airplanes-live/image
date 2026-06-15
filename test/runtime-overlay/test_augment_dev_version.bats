#!/usr/bin/env bats

# Tests for runtime-overlay/scripts/lib/augment-dev-version.sh — folds a
# fingerprint of the bundled payload (component commits + mlat venv hash) into
# an auto-generated dev version so a component-only change on the same image
# commit/date still produces a distinct, installable version.
#
# These are pure-function tests: synthetic components.json / compat.json, no
# real build. Holding the base version constant and varying only the payload is
# what proves the fix — a real merge bumps the image sha too, so it would yield
# a new version under the old scheme regardless.

bats_require_minimum_version 1.5.0

# The auto dev form resolve-channel-and-tags.sh emits: image sha is exactly 7 hex.
BASE="0.0.1-dev-20260603-ec4b72e"

# Matches install-common.sh's device-side dev-version check and the schema.
DEV_RE='^[0-9]+\.[0-9]+\.[0-9]+-dev-[0-9]{8}-[0-9a-f]{7,40}$'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HELPER="$REPO_ROOT/runtime-overlay/scripts/lib/augment-dev-version.sh"
    [ -x "$HELPER" ] || skip "augment-dev-version.sh not executable: $HELPER"

    STAGING="$BATS_TEST_TMPDIR/staging"
    install -d -m 0755 "$STAGING"
}

# Write a components.json with a single webconfig pin (bare-sha form).
write_components() {
    printf '{"webconfig":"%s","feed":"%s"}\n' "$1" "$2" > "$STAGING/components.json"
}

augment() {
    "$HELPER" --base-version "$BASE" --staging "$STAGING"
}

@test "auto-dev base gains a 16-hex fingerprint and still matches the dev regex" {
    write_components "a1b2c3d4e5f6789012345678901234567890abcd" \
                     "0fedcba987654321fedcba9876543210fedcba98"
    run augment
    [ "$status" -eq 0 ]
    # base (…-ec4b72e) plus exactly 16 hex appended.
    [[ "$output" == "$BASE"* ]]
    suffix="${output#"$BASE"}"
    [ "${#suffix}" -eq 16 ]
    [[ "$suffix" =~ ^[0-9a-f]{16}$ ]]
    [[ "$output" =~ $DEV_RE ]]
}

@test "a different component sha yields a different version" {
    write_components "a1b2c3d4e5f6789012345678901234567890abcd" \
                     "0fedcba987654321fedcba9876543210fedcba98"
    run augment
    [ "$status" -eq 0 ]
    local first="$output"

    write_components "ffffffffffffffffffffffffffffffffffffffff" \
                     "0fedcba987654321fedcba9876543210fedcba98"
    run augment
    [ "$status" -eq 0 ]
    [ "$output" != "$first" ]
}

@test "identical payload yields an identical version" {
    write_components "a1b2c3d4e5f6789012345678901234567890abcd" \
                     "0fedcba987654321fedcba9876543210fedcba98"
    run augment
    [ "$status" -eq 0 ]
    local first="$output"
    run augment
    [ "$status" -eq 0 ]
    [ "$output" = "$first" ]
}

@test "object-form and bare-sha pins fingerprint identically when the commit matches" {
    write_components "a1b2c3d4e5f6789012345678901234567890abcd" \
                     "0fedcba987654321fedcba9876543210fedcba98"
    run augment
    [ "$status" -eq 0 ]
    local bare="$output"

    # Same commits, but webconfig carries a {commit_sha, version} object — as
    # aggregate-components-json.sh emits when a components.<key>.version exists.
    printf '{"webconfig":{"commit_sha":"%s","version":"v0.1.3"},"feed":"%s"}\n' \
        "a1b2c3d4e5f6789012345678901234567890abcd" \
        "0fedcba987654321fedcba9876543210fedcba98" > "$STAGING/components.json"
    run augment
    [ "$status" -eq 0 ]
    [ "$output" = "$bare" ]
}

@test "a changed mlat venv hash yields a different version at the same commits" {
    write_components "a1b2c3d4e5f6789012345678901234567890abcd" \
                     "0fedcba987654321fedcba9876543210fedcba98"
    printf '{"mlat_venv_sha256":"1111111111111111111111111111111111111111111111111111111111111111"}\n' \
        > "$STAGING/compat.json"
    run augment
    [ "$status" -eq 0 ]
    local first="$output"

    printf '{"mlat_venv_sha256":"2222222222222222222222222222222222222222222222222222222222222222"}\n' \
        > "$STAGING/compat.json"
    run augment
    [ "$status" -eq 0 ]
    [ "$output" != "$first" ]
}

@test "a stable X.Y.Z version passes through untouched" {
    write_components "a1b2c3d4e5f6789012345678901234567890abcd" \
                     "0fedcba987654321fedcba9876543210fedcba98"
    run "$HELPER" --base-version "1.4.0" --staging "$STAGING"
    [ "$status" -eq 0 ]
    [ "$output" = "1.4.0" ]
}

@test "an explicit longer-suffix dev override passes through untouched" {
    write_components "a1b2c3d4e5f6789012345678901234567890abcd" \
                     "0fedcba987654321fedcba9876543210fedcba98"
    # A 23-hex suffix (already-fingerprinted shape) must not be re-fingerprinted.
    local override="0.0.1-dev-20260603-ec4b72e0123456789abcdef"
    run "$HELPER" --base-version "$override" --staging "$STAGING"
    [ "$status" -eq 0 ]
    [ "$output" = "$override" ]
}

@test "auto-dev base with a missing components.json fails loudly" {
    run augment
    [ "$status" -ne 0 ]
    [[ "$output" == *"components.json"* ]]
}
