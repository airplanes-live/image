#!/usr/bin/env bats

# Tests the on-device compat preflight (runtime-mode only).
# Covers:
#   - missing compat block → satisfied (no-op)
#   - requires_webconfig satisfied / violated
#   - missing webconfig-release.json with a requires_webconfig clause fails
#   - requires_feed_contract satisfied / violated
#   - min_image_base satisfied / violated

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
}

write_manifest_with_compat() {
    local path="$1" compat="$2"
    cat > "$path" <<JSON
{
    "version": "1.0.0", "channel": "stable",
    "managed_paths": [], "mutable_paths": [],
    "compat": $compat
}
JSON
}

@test "no compat block → satisfied" {
    cat > "$BATS_TEST_TMPDIR/manifest.json" <<'JSON'
{ "version": "1.0.0", "channel": "stable" }
JSON
    run airplanes_runtime_run_compat_preflight "$BATS_TEST_TMPDIR/manifest.json" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
}

@test "requires_webconfig satisfied" {
    write_manifest_with_compat "$BATS_TEST_TMPDIR/manifest.json" \
        '{ "requires_webconfig": ">=2.1.0,<2.3.0" }'
    printf '{"version":"2.2.5"}\n' > "$TARGET_ROOT/etc/airplanes/webconfig-release.json"
    run airplanes_runtime_run_compat_preflight "$BATS_TEST_TMPDIR/manifest.json" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
}

@test "requires_webconfig violated (too old)" {
    write_manifest_with_compat "$BATS_TEST_TMPDIR/manifest.json" \
        '{ "requires_webconfig": ">=2.1.0,<2.3.0" }'
    printf '{"version":"2.0.4"}\n' > "$TARGET_ROOT/etc/airplanes/webconfig-release.json"
    run airplanes_runtime_run_compat_preflight "$BATS_TEST_TMPDIR/manifest.json" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"webconfig"* ]]
}

@test "requires_webconfig violated (too new)" {
    write_manifest_with_compat "$BATS_TEST_TMPDIR/manifest.json" \
        '{ "requires_webconfig": ">=2.1.0,<2.3.0" }'
    printf '{"version":"2.3.0"}\n' > "$TARGET_ROOT/etc/airplanes/webconfig-release.json"
    run airplanes_runtime_run_compat_preflight "$BATS_TEST_TMPDIR/manifest.json" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
}

@test "requires_webconfig with no webconfig installed fails actionably" {
    write_manifest_with_compat "$BATS_TEST_TMPDIR/manifest.json" \
        '{ "requires_webconfig": ">=2.1.0" }'
    run airplanes_runtime_run_compat_preflight "$BATS_TEST_TMPDIR/manifest.json" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"webconfig-release.json"* ]]
}

@test "requires_feed_contract satisfied via /etc/airplanes/feed-contract" {
    write_manifest_with_compat "$BATS_TEST_TMPDIR/manifest.json" \
        '{ "requires_feed_contract": ">=14" }'
    printf '15\n' > "$TARGET_ROOT/etc/airplanes/feed-contract"
    run airplanes_runtime_run_compat_preflight "$BATS_TEST_TMPDIR/manifest.json" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
}

@test "requires_feed_contract violated when file missing and clause is >=N (N>0)" {
    write_manifest_with_compat "$BATS_TEST_TMPDIR/manifest.json" \
        '{ "requires_feed_contract": ">=14" }'
    run airplanes_runtime_run_compat_preflight "$BATS_TEST_TMPDIR/manifest.json" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"feed contract"* ]]
}

@test "min_image_base satisfied" {
    write_manifest_with_compat "$BATS_TEST_TMPDIR/manifest.json" \
        '{ "min_image_base": ">=1.2.0" }'
    printf '{"version":"1.5.0"}\n' > "$TARGET_ROOT/etc/airplanes/build-manifest.json"
    run airplanes_runtime_run_compat_preflight "$BATS_TEST_TMPDIR/manifest.json" "$TARGET_ROOT"
    [ "$status" -eq 0 ]
}

@test "min_image_base violated" {
    write_manifest_with_compat "$BATS_TEST_TMPDIR/manifest.json" \
        '{ "min_image_base": ">=1.2.0" }'
    printf '{"version":"1.0.0"}\n' > "$TARGET_ROOT/etc/airplanes/build-manifest.json"
    run airplanes_runtime_run_compat_preflight "$BATS_TEST_TMPDIR/manifest.json" "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"image base"* ]]
}
