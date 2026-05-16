#!/usr/bin/env bash
# Host-side helpers for the webconfig-upgrade variant of the image boot smoke.
#
# Split in two:
#   - build_synthetic_releases_prebuild: runs OUTSIDE the sudo harness on the
#     CI runner. setup-go put `go` in the runner-user PATH; sudo's secure_path
#     strips that. Building synthetic releases pre-sudo, then handing the
#     output dir into the sudo harness, avoids the PATH-in-sudo footgun.
#   - install_synthetic_releases: runs INSIDE the sudo harness from
#     test/boot-smoke/setup.sh. Copies the prebuilt releases onto $ROOT_MNT,
#     wires the test wrapper update.sh, bare git repo, push-tag helper, and
#     sudoers test grant.

# build_synthetic_releases_prebuild WEBCONFIG_SRC OUT_DIR CHANNEL
#
# Produces $OUT_DIR/{good,broken} with the synthetic release payloads. Runs
# pre-sudo on the CI runner. Needs Go on PATH.
build_synthetic_releases_prebuild() {
    local webconfig_src="$1"
    local out_dir="$2"
    local channel="$3"

    [[ -d "$webconfig_src" ]] || { echo "ERROR: image-webconfig source $webconfig_src missing" >&2; return 1; }
    [[ -x "$webconfig_src/scripts/lib/build-release.sh" ]] || {
        echo "ERROR: $webconfig_src has no scripts/lib/build-release.sh" >&2; return 1; }
    case "$channel" in
        stable|dev) ;;
        *) echo "ERROR: unknown channel '$channel' (expected stable or dev)" >&2; return 1 ;;
    esac
    command -v go >/dev/null || { echo "ERROR: go not on PATH (need setup-go in the workflow)" >&2; return 1; }

    rm -rf "$out_dir"
    install -d -m 0755 "$out_dir"

    local good_tag broken_tag
    case "$channel" in
        stable) good_tag=v9.9.99;    broken_tag=v9.9.100 ;;
        dev)    good_tag=dev-latest; broken_tag=dev-latest ;;
    esac

    echo "webconfig-upgrade-helpers: building synthetic releases (channel=$channel) → $out_dir"

    bash "$webconfig_src/scripts/lib/build-release.sh" \
        --version "$good_tag" \
        --kind "$channel" \
        --source "$webconfig_src" \
        --output "$out_dir/good" \
        --arch arm64 \
        --build-date 2024-01-01T00:00:00Z

    bash "$webconfig_src/scripts/lib/build-release.sh" \
        --version "$broken_tag" \
        --kind "$channel" \
        --source "$webconfig_src" \
        --output "$out_dir/broken" \
        --arch arm64 \
        --build-date 2024-01-01T00:00:00Z

    # Replace broken's binary with a shell script that starts under systemd
    # but never binds :8080. Helper's /health probe exhausts in 10s and the
    # rollback fires. Zero-byte binaries fail at `systemctl restart` instead,
    # exercising the wrong branch.
    cat > "$out_dir/broken/airplanes-webconfig-arm64" <<'BROKEN'
#!/bin/sh
trap 'exit 0' TERM
while :; do
    sleep 30
done
BROKEN
    chmod 0755 "$out_dir/broken/airplanes-webconfig-arm64"
    # Re-checksum only the assets actually present (build-release.sh wrote
    # arm64 only since we passed --arch arm64).
    (
        cd "$out_dir/broken" || exit 1
        : > SHA256SUMS
        for f in airplanes-webconfig-* rootfs.tar.gz manifest.json; do
            sha256sum "$f"
        done > SHA256SUMS
    )

    # Repack rootfs tarballs so the test wrapper update.sh is laid down by
    # any in-test upgrade — without this, an upgrade extracts the production
    # update.sh and any subsequent upgrade tries to reach github.com.
    _wcu_repack_release_with_wrapper "$out_dir/good"
    _wcu_repack_release_with_wrapper "$out_dir/broken"
}

# install_synthetic_releases ROOT PREBUILT_DIR CHANNEL
#
# Runs INSIDE the sudo harness. Copies prebuilt releases onto $ROOT and
# wires the rest of the test plumbing.
install_synthetic_releases() {
    local root="$1"
    local prebuilt="$2"
    local channel="$3"

    [[ -d "$root" ]] || { echo "ERROR: rootfs $root missing" >&2; return 1; }
    [[ -d "$prebuilt/good" && -d "$prebuilt/broken" ]] || {
        echo "ERROR: prebuilt dir $prebuilt missing good/ or broken/" >&2; return 1; }
    case "$channel" in
        stable|dev) ;;
        *) echo "ERROR: unknown channel '$channel'" >&2; return 1 ;;
    esac

    local staged_in_image=/opt/airplanes-webconfig-test-releases
    local staged_host="$root$staged_in_image"
    rm -rf "$staged_host"
    install -d -m 0755 "$staged_host"

    # Place GOOD payload at the channel-specific download path so the
    # resolver's $DOWNLOAD_BASE/$tag/ URL resolves on Phase A. BROKEN stays
    # at a separate path; push-broken-tag.sh rotates it into the resolver's
    # path between phases.
    case "$channel" in
        stable)
            cp -a "$prebuilt/good"   "$staged_host/v9.9.99"
            cp -a "$prebuilt/broken" "$staged_host/v9.9.100"
            ;;
        dev)
            cp -a "$prebuilt/good"   "$staged_host/dev-latest"
            cp -a "$prebuilt/broken" "$staged_host/.broken"
            ;;
    esac

    # Bare git repo carrying the channel-specific initial tag layout.
    local remote_in_image=$staged_in_image/image-webconfig.git
    local remote_host="$root$remote_in_image"
    git init -q --bare "$remote_host"
    local seed
    seed=$(mktemp -d)
    git init -q "$seed"
    (
        cd "$seed" || exit 1
        git config user.email t@example.com
        git config user.name boot-smoke
        git commit --allow-empty -q -m "test seed"
        case "$channel" in
            stable)
                # Only v9.9.99 visible — push-broken-tag.sh adds v9.9.100
                # before Phase B (becomes the new highest semver).
                git tag v9.9.99
                ;;
            dev)
                # Single moving tag. The payload dir at $STAGED/dev-latest
                # is what actually changes between phases; the tag is force-
                # pushed only because the dev resolver does
                # `git ls-remote refs/tags/dev-latest` and refuses an empty
                # result.
                git tag dev-latest
                ;;
        esac
        git remote add origin "$remote_host"
        git push -q origin --tags
    )
    rm -rf "$seed"

    # Test wrapper update.sh — replaces the production update.sh installed
    # by stage 05's real release. Mirrors production: flock around install.sh
    # so the concurrency guard still works, then export file:// URLs the
    # helper's env -i would otherwise scrub.
    _wcu_write_test_wrapper_to "$root/usr/local/share/airplanes-webconfig/update.sh"

    # In-VM helper that flips the resolver target between phases. Sudoers-
    # pinned argv below; runs as root via sudo. The unprivileged
    # airplanes-webconfig user invokes this exactly once, between Phase A
    # and Phase B.
    install -d -m 0755 "$root/usr/local/lib/airplanes-boot-smoke"
    cat > "$root/usr/local/lib/airplanes-boot-smoke/push-broken-tag.sh" <<PUSHTAG
#!/bin/bash
# Boot-smoke test helper. After the in-VM probe has finished Phase A
# (the happy-path upgrade to the good release) it invokes this script
# to make the broken release reachable so the helper's rollback path
# can be exercised in Phase B.
set -euo pipefail
REMOTE=$remote_in_image
STAGED=$staged_in_image
case "\$1" in
    stable)
        SEED=\$(mktemp -d)
        git init -q "\$SEED"
        (
            cd "\$SEED"
            git config user.email t@example.com
            git config user.name boot-smoke
            git commit --allow-empty -q -m "broken seed"
            git tag v9.9.100
            git remote add origin "\$REMOTE"
            git push -q origin --tags
        )
        rm -rf "\$SEED"
        ;;
    dev)
        # Atomic rotation: stage .broken contents in a sibling dir first,
        # then mv -T over the live dev-latest dir, then update the bare
        # repo's dev-latest tag. Doing dir rotation before the tag move
        # means the dev resolver's tag-check + download window never sees
        # a partial state.
        rm -rf "\$STAGED/dev-latest.new"
        cp -a "\$STAGED/.broken" "\$STAGED/dev-latest.new"
        mv -T "\$STAGED/dev-latest.new" "\$STAGED/dev-latest"
        SEED=\$(mktemp -d)
        git init -q "\$SEED"
        (
            cd "\$SEED"
            git config user.email t@example.com
            git config user.name boot-smoke
            git commit --allow-empty -q -m "broken seed dev"
            git tag -f dev-latest
            git remote add origin "\$REMOTE"
            git push -qf origin refs/tags/dev-latest
        )
        rm -rf "\$SEED"
        ;;
    *) echo "ERROR: channel must be stable or dev (got '\$1')" >&2; exit 2 ;;
esac
PUSHTAG
    chmod 0755 "$root/usr/local/lib/airplanes-boot-smoke/push-broken-tag.sh"

    # Sudoers grant for the unprivileged webconfig user to invoke the helper.
    # Ships only in test images — never present in a production rootfs.
    install -d -m 0755 "$root/etc/sudoers.d"
    cat > "$root/etc/sudoers.d/099_airplanes-boot-smoke-test" <<'SUDOERS'
airplanes-webconfig ALL=(root) NOPASSWD: /usr/local/lib/airplanes-boot-smoke/push-broken-tag.sh stable
airplanes-webconfig ALL=(root) NOPASSWD: /usr/local/lib/airplanes-boot-smoke/push-broken-tag.sh dev
SUDOERS
    chmod 0440 "$root/etc/sudoers.d/099_airplanes-boot-smoke-test"

    # Pass channel into the in-VM probe.
    install -d -m 0755 "$root/var/lib/airplanes-boot-smoke"
    printf '%s' "$channel" > "$root/var/lib/airplanes-boot-smoke/webconfig-upgrade-channel"

    echo "webconfig-upgrade-helpers: staged $staged_in_image (channel=$channel)"
}

# _wcu_write_test_wrapper_to PATH — writes the test wrapper update.sh that
# exports file:// URLs into PATH (production update.sh minus the exports).
_wcu_write_test_wrapper_to() {
    local target="$1"
    install -d -m 0755 "$(dirname "$target")"
    cat > "$target" <<'WRAPPER'
#!/bin/bash
# Boot-smoke test wrapper for /usr/local/share/airplanes-webconfig/update.sh.
# Production update.sh is the same minus the exports below; the wrapper is
# staged by the boot-smoke pre-boot setup so the unprivileged self-update
# path resolves to file:// URLs on the rootfs.
set -euo pipefail
LOCK_DIR="${AIRPLANES_WEBCONFIG_LOCK_DIR:-/run/airplanes}"
LOCK_FILE="$LOCK_DIR/webconfig-update.lock"
install -d -m 0755 "$LOCK_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "ERROR: another webconfig update is in progress (lock held: $LOCK_FILE)" >&2
    exit 75
fi
export AIRPLANES_WEBCONFIG_REPO="file:///opt/airplanes-webconfig-test-releases/image-webconfig.git"
export AIRPLANES_WEBCONFIG_DOWNLOAD_BASE="file:///opt/airplanes-webconfig-test-releases"
exec bash /usr/local/share/airplanes-webconfig/install.sh --runtime
WRAPPER
    chmod 0755 "$target"
}

# Repack release_dir/rootfs.tar.gz to replace its update.sh with the test
# wrapper. Without this, the first in-test upgrade extracts the production
# update.sh and any subsequent upgrade tries to reach github.com.
_wcu_repack_release_with_wrapper() {
    local release_dir="$1"
    local tmp
    tmp=$(mktemp -d)
    tar -C "$tmp" -xzf "$release_dir/rootfs.tar.gz"
    _wcu_write_test_wrapper_to "$tmp/usr/local/share/airplanes-webconfig/update.sh"
    tar -C "$tmp" \
        --owner=0 --group=0 --numeric-owner \
        --mtime='2024-01-01 00:00:00 UTC' \
        --sort=name \
        -czf "$release_dir/rootfs.tar.gz" .
    # Glob the arch binaries — build-release.sh was called with --arch arm64
    # so only the arm64 file exists; hardcoding both arches here would make
    # sha256sum fail on the missing armhf file.
    (
        cd "$release_dir" || exit 1
        : > SHA256SUMS
        for f in airplanes-webconfig-* rootfs.tar.gz manifest.json; do
            sha256sum "$f"
        done > SHA256SUMS
    )
    rm -rf "$tmp"
}
