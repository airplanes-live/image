#!/bin/bash -e

: "${AIRPLANES_FEED_REPO:?AIRPLANES_FEED_REPO must be set by config-stable/dev}"
: "${AIRPLANES_FEED_BRANCH:?AIRPLANES_FEED_BRANCH must be set by config-stable/dev}"

FEED_BUILD_DIR="${ROOTFS_DIR}/usr/local/src/airplanes-feed-build"

# init+fetch+checkout works for branches and SHAs uniformly. `-B` creates a
# local branch ref named `${AIRPLANES_FEED_BRANCH}` so feed/install.sh's
# in-chroot `git clone --branch ${AIRPLANES_FEED_BRANCH} file://...` re-clone
# resolves. (For SHA-pinned stable, the local branch name happens to be the
# 40-char SHA, which git accepts as a valid branch name.)
rm -rf "${FEED_BUILD_DIR}"
install -d -m 755 "${FEED_BUILD_DIR}"
git -C "${FEED_BUILD_DIR}" init -q
git -C "${FEED_BUILD_DIR}" remote add origin "${AIRPLANES_FEED_REPO}"
git -C "${FEED_BUILD_DIR}" fetch --depth 1 origin "${AIRPLANES_FEED_BRANCH}"
git -C "${FEED_BUILD_DIR}" checkout -q -B "${AIRPLANES_FEED_BRANCH}" FETCH_HEAD

# Record the resolved feed SHA for the build manifest.
git -C "${FEED_BUILD_DIR}" rev-parse HEAD > "${ROOTFS_DIR}/etc/airplanes/.build-feed-sha"
