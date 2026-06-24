#!/usr/bin/env bats

# A HEALTH_PASSED state means a prior install's health gates passed but the
# cleanup/GC post-step was interrupted. The boot recovery shim only no-ops on
# HEALTH_PASSED (pointer recovery can't finish cleanup), so the NEXT
# invocation of runtime-self-update.sh must resume the cleanup before starting
# a fresh attempt. These tests exercise the resume-on-entry path and the
# install-common helpers it relies on.

bats_require_minimum_version 1.5.0

load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
}

@test "write_last_good_release records the device-canonical path" {
    airplanes_runtime_write_last_good_release "$TARGET_ROOT" \
        "/opt/airplanes/releases/v1.2.3"
    local f="$TARGET_ROOT/var/lib/airplanes/runtime/last-good-release"
    [ -f "$f" ]
    [ "$(head -n1 "$f")" = "/opt/airplanes/releases/v1.2.3" ]
}

@test "write_last_good_release rejects a relative path" {
    run airplanes_runtime_write_last_good_release "$TARGET_ROOT" "relative/path"
    [ "$status" -ne 0 ]
}

@test "finalize_after_health_passed writes the runtime-manifest pointer and GCs" {
    # Stage a release and point current at it so record_runtime_manifest can
    # resolve the manifest.
    local rel
    rel="$(mk_target_release "$TARGET_ROOT" 1.0.0)"
    rm -f "$TARGET_ROOT/opt/airplanes/current"
    ln -s "/opt/airplanes/releases/v1.0.0" \
        "$TARGET_ROOT/opt/airplanes/current"

    # Runtime mode (not build mode) so a symlink pointer is written.
    AIRPLANES_BUILD_MODE=0 \
        run airplanes_runtime_finalize_after_health_passed "$TARGET_ROOT"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_ROOT/etc/airplanes/runtime-manifest.json" ]
}

# Write a manifest with symlink-mode managed_paths links into <dir>.
# Args: <dir> <link1> <link2> ...
_mk_resume_manifest() {
    local dir="$1"; shift
    local entries="" first=1 link
    for link in "$@"; do
        [[ $first -eq 0 ]] && entries="$entries,"
        entries="$entries {\"mode\":\"symlink\",\"link\":\"$link\",\"target\":\"/opt/airplanes/current/bin/dummy\"}"
        first=0
    done
    cat > "$dir/manifest.json" <<JSON
{
    "manifest_schema_version": 1,
    "installer_min_version": "1.0.0",
    "version": "1.0.0",
    "channel": "stable",
    "commit_sha": "0000000000000000000000000000000000000000",
    "build_date": "2026-05-20T00:00:00Z",
    "arches": ["arm64"],
    "components": { "readsb_wiedehopf": "0000000" },
    "managed_paths": [ $entries ],
    "mutable_paths": [],
    "systemd": { "enable": [], "daemon_reload": true },
    "migrations": []
}
JSON
}

@test "finalize_after_health_passed removes retired symlinks on resume (reads prev/new from state file)" {
    # This is the resume-path guarantee: a power loss after HEALTH_PASSED but
    # before retired-symlink cleanup must still drop the prior release's
    # retired links when the next invocation finalizes. finalize derives the
    # prev/new release dirs from the persisted state file, NOT from forward-walk
    # shell vars (which are absent on a fresh resume invocation).
    local rel_dir="$TARGET_ROOT/opt/airplanes/releases"
    local prev_dir="$rel_dir/v1.0.0"
    local new_dir="$rel_dir/v1.1.0"
    install -d "$prev_dir" "$new_dir"

    # prev owned old-tool + shared-tool; new owns shared-tool only → old-tool
    # is retired.
    _mk_resume_manifest "$prev_dir" "/usr/bin/old-tool" "/usr/bin/shared-tool"
    _mk_resume_manifest "$new_dir"  "/usr/bin/shared-tool"

    # The FHS links as the prior install left them.
    install -d -m 755 "$TARGET_ROOT/usr/bin"
    ln -s /opt/airplanes/current/bin/dummy "$TARGET_ROOT/usr/bin/old-tool"
    ln -s /opt/airplanes/current/bin/dummy "$TARGET_ROOT/usr/bin/shared-tool"

    # current points at the new (known-good) release.
    rm -f "$TARGET_ROOT/opt/airplanes/current"
    ln -s "/opt/airplanes/releases/v1.1.0" \
        "$TARGET_ROOT/opt/airplanes/current"

    # The interrupted attempt's persisted state: HEALTH_PASSED with prev/new
    # pinned (absolute, target_root-prefixed — as the forward walk records).
    airplanes_runtime_state_write "$TARGET_ROOT" HEALTH_PASSED \
        "prev_release=$prev_dir" "new_release=$new_dir"

    AIRPLANES_BUILD_MODE=0 \
        run airplanes_runtime_finalize_after_health_passed "$TARGET_ROOT"
    [ "$status" -eq 0 ]

    # Retired link gone; shared link (in both manifests) retained.
    [ ! -e "$TARGET_ROOT/usr/bin/old-tool" ]
    [ -L "$TARGET_ROOT/usr/bin/shared-tool" ]
}
