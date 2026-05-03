#!/bin/bash -e

: "${AIRPLANES_FEED_REPO:?AIRPLANES_FEED_REPO must be set by config-stable/dev}"
: "${AIRPLANES_FEED_BRANCH:?AIRPLANES_FEED_BRANCH must be set by config-stable/dev}"

FEED_BUILD_DIR="${ROOTFS_DIR}/usr/local/src/airplanes-feed-build"

rm -rf "${FEED_BUILD_DIR}"
install -d -m 755 "${FEED_BUILD_DIR}"

git clone --depth 1 --branch "${AIRPLANES_FEED_BRANCH}" \
	"${AIRPLANES_FEED_REPO}" "${FEED_BUILD_DIR}"

# Record the resolved feed SHA so a later manifest stage can fold it into
# /etc/airplanes/build-manifest.json.
git -C "${FEED_BUILD_DIR}" rev-parse HEAD > "${ROOTFS_DIR}/etc/airplanes/.build-feed-sha"
