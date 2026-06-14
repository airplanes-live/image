#!/usr/bin/env bats

# The on-device webconfig runs unprivileged and reads manifest.json for
# /api/status. Historical release tarballs packed it 0600 (mktemp default),
# so extraction must normalize it to 0644 regardless of the tarball's recorded
# mode — covering older/pinned/local tarballs built before the render fix.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
}

@test "extract normalizes a 0600 manifest.json to 0644" {
    local src="$BATS_TEST_TMPDIR/rel"
    install -d -m 755 "$src"
    printf '{"version":"1.0.0"}\n' > "$src/manifest.json"
    chmod 0600 "$src/manifest.json"
    # Pack with a top-level dir so --strip-components=1 lands the tree at target.
    local tarball="$BATS_TEST_TMPDIR/release.tgz"
    tar -czf "$tarball" -C "$BATS_TEST_TMPDIR" rel

    local target="$BATS_TEST_TMPDIR/out"
    run airplanes_runtime_extract_release_tarball "$tarball" "$target"
    [ "$status" -eq 0 ]
    [ -f "$target/manifest.json" ]

    run stat -c '%a' "$target/manifest.json"
    [ "$status" -eq 0 ]
    [ "$output" = "644" ]
}
