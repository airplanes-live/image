#!/usr/bin/env bash
# Shared prelude for the chroot-side smoke runners (overlay-smoke-inner.sh,
# update-regression-inner.sh). Sourced once at the top of each runner; sets
# up the pi-gen env vars stage scripts expect, installs the apt deps that
# match production builds, and configures git to tolerate the bind-mounted
# feed checkout.
#
# Call after the runner has set `set -euo pipefail` (so apt failures
# propagate). Caller can override ARCH before sourcing if it wants
# something other than arm64.

# Pi-gen helpers expected by stage scripts: on_chroot wraps a heredoc to run
# inside the chroot. We're already inside the rootfs (the container), so
# just execute the heredoc body in the current shell.
on_chroot() { bash; }
export -f on_chroot

# Stage scripts read ROOTFS_DIR / BASE_DIR from pi-gen. Map to container root.
export ROOTFS_DIR=/
export BASE_DIR=/image

# Source config-dev for CHANNEL=dev (and the runtime update channel). The
# component repo/branch pins now live in runtime-overlay/config-dev; this file
# overrides AIRPLANES_FEED_REPO to the bind-mounted checkout (below) and takes
# the feed branch from the caller. Capture the caller-supplied
# AIRPLANES_FEED_BRANCH first so a sourced default can't clobber it (the feed-CI
# gate runs the smoke against a PR head branch, image-CI against feed/dev).
caller_feed_branch="${AIRPLANES_FEED_BRANCH:-}"
set -a
. /image/config-dev
set +a
if [[ -n "$caller_feed_branch" ]]; then
    export AIRPLANES_FEED_BRANCH="$caller_feed_branch"
fi
unset caller_feed_branch

# Override AIRPLANES_FEED_REPO to the bind-mounted local checkout. Other
# repos (airplanes-readsb, mlat-client) are fetched from GitHub during the
# smoke, same as the real build.
export AIRPLANES_FEED_REPO="file:///feed"

# Stage 07 invokes manifest-generator.sh which requires ARCH. The smoke runs
# in a debian:trixie-slim container regardless of host arch — default to
# arm64 to match config-dev's primary target. CHANNEL=dev comes from
# config-dev.
export ARCH="${ARCH:-arm64}"

echo "==> apt update + stage-00-prep packages"
apt-get update -qq
# Install only what stage-00-prep declares; install.sh fetches its own
# bootstrap deps inside the chroot via airplanes_install_update_deps.
mapfile -t stage00_packages < <(grep -v '^#' /image/stage-airplanes/00-prep/01-packages)
apt-get install -y --no-install-recommends "${stage00_packages[@]}"
# systemd provides /bin/systemctl. The stub passes 'enable' through to it;
# without /bin/systemctl, enables silently no-op and leave no symlink under
# target.wants/, so post-install assertions can't tell whether enable worked.
apt-get install -y --no-install-recommends systemd

# Stage 05 cross-builds the webconfig Go binary on the build host before
# entering the chroot. golang-go is in image/depends; install it here too so
# the smoke exercises the same cross-build path production uses. `file` is
# used downstream to assert the cross-built ELF matches ARCH.
apt-get install -y --no-install-recommends golang-go file

# git refuses to operate on bind-mounted feed checkout owned by a different
# uid (runner host vs. root in container); mirror feed/test/installer-smoke's
# fix. Has to run after git is installed.
git config --system --add safe.directory '*'
