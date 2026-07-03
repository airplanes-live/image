#!/usr/bin/env bats

# Tests the feed health gate: feed_readsb manifest extractor, the
# feed-binary-resolves-into-current invariant, and confirms airplanes-feed
# is in the restart/stop/rollback lists. The gate is "service active +
# correct binary" only — connectivity / sync state must never gate the
# update, so there is deliberately no connectivity probe to test here.

bats_require_minimum_version 1.5.0

# shellcheck source=test/runtime-overlay/lib/install_test_helpers.bash
load lib/install_test_helpers

setup() {
    source_install_lib
    TARGET_ROOT="$(mk_target_root "$BATS_TEST_TMPDIR")"
}

# --- feed_readsb manifest short-sha extractor -------------------------------

@test "manifest_feed_readsb_short_sha: object component" {
    local m="$BATS_TEST_TMPDIR/manifest.json"
    cat > "$m" <<'JSON'
{"components":{"feed_readsb":{"commit_sha":"b499ecbd18dc4a2ec6098c31de31508017fa6190","version":"dev"}}}
JSON
    local sha
    sha="$(_airplanes_runtime_manifest_feed_readsb_short_sha "$m")"
    [ "$sha" = "b499ecb" ]
}

@test "manifest_feed_readsb_short_sha: bare string component" {
    local m="$BATS_TEST_TMPDIR/manifest.json"
    cat > "$m" <<'JSON'
{"components":{"feed_readsb":"abcdef0123456789abcdef0123456789abcdef01"}}
JSON
    local sha
    sha="$(_airplanes_runtime_manifest_feed_readsb_short_sha "$m")"
    [ "$sha" = "abcdef0" ]
}

@test "manifest_feed_readsb_short_sha: no feed_readsb component → empty" {
    local m="$BATS_TEST_TMPDIR/manifest.json"
    cat > "$m" <<'JSON'
{"components":{"readsb_wiedehopf":"abcdef0"}}
JSON
    local sha
    sha="$(_airplanes_runtime_manifest_feed_readsb_short_sha "$m")"
    [ -z "$sha" ]
}

# --- feed binary-identity gate ----------------------------------------------

@test "feed binary gate: passes when feed-airplanes resolves into current" {
    # Build a fake release tree + current symlink with a feed binary. The gate
    # checks /opt/airplanes/current/bin/feed-airplanes directly. All paths are
    # under TARGET_ROOT so readlink -f resolves correctly on the host.
    local rel="$TARGET_ROOT/opt/airplanes/releases/v1.0.0"
    install -d -m 755 "$rel/bin"
    printf '#!/bin/sh\n' > "$rel/bin/feed-airplanes"
    chmod 0755 "$rel/bin/feed-airplanes"
    install -d -m 755 "$TARGET_ROOT/opt/airplanes"
    ln -sfn "$rel" "$TARGET_ROOT/opt/airplanes/current"

    run _airplanes_runtime_probe_feed_binary_current "$TARGET_ROOT"
    [ "$status" -eq 0 ]
}

@test "feed binary gate: fails when feed-airplanes resolves outside current" {
    # current points at v1.0.0 but its feed-airplanes is itself a symlink to a
    # stale v0.9.0 binary, so the running binary resolves out of the release.
    local rel_new="$TARGET_ROOT/opt/airplanes/releases/v1.0.0"
    local rel_old="$TARGET_ROOT/opt/airplanes/releases/v0.9.0"
    install -d -m 755 "$rel_new/bin" "$rel_old/bin"
    printf '#!/bin/sh\n' > "$rel_old/bin/feed-airplanes"
    chmod 0755 "$rel_old/bin/feed-airplanes"
    ln -sfn "$rel_old/bin/feed-airplanes" "$rel_new/bin/feed-airplanes"
    install -d -m 755 "$TARGET_ROOT/opt/airplanes"
    ln -sfn "$rel_new" "$TARGET_ROOT/opt/airplanes/current"

    run _airplanes_runtime_probe_feed_binary_current "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"outside active release"* ]]
}

@test "feed binary gate: fails when the feed binary is missing" {
    # current exists but the active release ships no bin/feed-airplanes.
    local rel="$TARGET_ROOT/opt/airplanes/releases/v1.0.0"
    install -d -m 755 "$rel/bin"
    install -d -m 755 "$TARGET_ROOT/opt/airplanes"
    ln -sfn "$rel" "$TARGET_ROOT/opt/airplanes/current"
    run _airplanes_runtime_probe_feed_binary_current "$TARGET_ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing"* ]]
}

# --- restart order membership -----------------------------------------------

@test "airplanes-feed.service is in the hardcoded restart order before webconfig" {
    local feed_idx=-1 wc_idx=-1 i=0 u
    for u in "${_airplanes_runtime_restart_order[@]}"; do
        [[ "$u" == "airplanes-feed.service" ]] && feed_idx=$i
        [[ "$u" == "airplanes-webconfig.service" ]] && wc_idx=$i
        i=$(( i + 1 ))
    done
    [ "$feed_idx" -ge 0 ]
    [ "$wc_idx" -ge 0 ]
    [ "$feed_idx" -lt "$wc_idx" ]
}

@test "airplanes-mlat.service is in the hardcoded restart order" {
    local found=0 u
    for u in "${_airplanes_runtime_restart_order[@]}"; do
        [[ "$u" == "airplanes-mlat.service" ]] && found=1
    done
    [ "$found" -eq 1 ]
}

# --- managed_paths + systemd.json declarations ------------------------------

@test "managed_paths.json declares apl-feed launcher and feed/mlat units" {
    local mp
    mp="$(cat "$BATS_TEST_DIRNAME/../../runtime-overlay/manifest-inputs/managed_paths.json")"
    local link
    # Only the /usr/local/bin launcher shim and the /etc unit symlinks are
    # managed. The feed binary, the *.sh wrappers, and the mlat-client venv
    # ride in the overlay payload under /opt/airplanes/current and are reached
    # by absolute path, not via a managed symlink.
    for link in \
        /usr/local/bin/apl-feed \
        /etc/systemd/system/airplanes-feed.service \
        /etc/systemd/system/airplanes-mlat.service; do
        local mode
        mode="$(printf '%s' "$mp" | jq -r --arg l "$link" '[.[] | select(.link == $l)][0].mode')"
        [ "$mode" = "symlink" ] || { echo "missing symlink managed_path for $link (got mode=$mode)" >&2; return 1; }
    done
    # De-squat: the feed payload must NOT be managed under /usr/local/share/airplanes.
    local squat
    for squat in \
        /usr/local/share/airplanes/feed-airplanes \
        /usr/local/share/airplanes/airplanes-feed.sh \
        /usr/local/share/airplanes/airplanes-mlat.sh; do
        if printf '%s' "$mp" | jq -e --arg l "$squat" 'any(.[]; .link == $l)' >/dev/null; then
            echo "unexpected managed squat for $squat" >&2
            return 1
        fi
    done
}

@test "systemd.json enables airplanes-feed and airplanes-mlat" {
    local sj
    sj="$(cat "$BATS_TEST_DIRNAME/../../runtime-overlay/manifest-inputs/systemd.json")"
    printf '%s' "$sj" | jq -e '.enable | index("airplanes-feed.service")' >/dev/null
    printf '%s' "$sj" | jq -e '.enable | index("airplanes-mlat.service")' >/dev/null
}
