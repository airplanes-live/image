#!/usr/bin/env bats

# Verifies that install.sh and update.sh resolve their script dir at startup
# (via readlink -f) so a rename or symlink redirect mid-process doesn't
# break sourcing of install-common.sh.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "install.sh resolves _self_dir via readlink -f, not BASH_SOURCE chain" {
    # Confirm the source uses readlink -f to pin self_dir.
    run grep -E '_self_dir=.*readlink -f' "$REPO_ROOT/runtime-overlay/install.sh"
    [ "$status" -eq 0 ]
}

@test "update.sh resolves _self_dir via readlink -f" {
    run grep -E '_self_dir=.*readlink -f' "$REPO_ROOT/runtime-overlay/update.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh sourced through a symlink still finds install-common.sh" {
    # Stage a symlink that points at the real install.sh and confirm the
    # script resolves its lib relative to the real path, not the link path.
    local link_dir="$BATS_TEST_TMPDIR/elsewhere"
    install -d -m 755 "$link_dir"
    ln -s "$REPO_ROOT/runtime-overlay/install.sh" "$link_dir/install.sh"

    # Run install.sh with an obviously wrong tag so it errors out, but we
    # only care that the lib was sourced successfully (otherwise bash dies
    # at the `airplanes_runtime_parse_mode_args` line). A `command not
    # found` would surface as exit 127.
    run env AIRPLANES_BUILD_MODE=1 ARCH=arm64 ROOTFS_DIR="$BATS_TEST_TMPDIR/rootfs" \
            AIRPLANES_RUNTIME_OVERLAY_TAG="runtime-v0.0.0-nonexistent" \
            AIRPLANES_RUNTIME_DOWNLOAD_BASE="file:///dev/null" \
            bash "$link_dir/install.sh" --build-mode
    # The script must reach at least the download step before failing.
    # If lib sourcing was broken we'd see "command not found".
    [[ "$output" != *"command not found"* ]]
    [[ "$output" != *"No such file or directory"* || "$output" == *"download"* || "$output" == *"runtime-overlay install"* ]]
}
