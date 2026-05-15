#!/bin/bash -e
# Clone airplanes-live/image-webconfig at the config-pinned ref and invoke
# its install.sh in build-mode. install.sh downloads the matching GitHub
# Release (per-arch binary + rootfs.tar.gz + manifest.json + SHA256SUMS),
# verifies SHA256 and that manifest.commit_sha equals the cloned HEAD, then
# lays the binary and rootfs payload into ${ROOTFS_DIR}. No Go toolchain
# runs in this stage — the binary is the prebuilt release asset.
#
# User creation, sudoers chmod/visudo, lighttpd module enable, and
# systemctl enable still happen in 01-run-chroot.sh.

: "${AIRPLANES_WEBCONFIG_REPO:?AIRPLANES_WEBCONFIG_REPO must be set by the active config}"
: "${AIRPLANES_WEBCONFIG_BRANCH:?AIRPLANES_WEBCONFIG_BRANCH must be set by the active config}"

# Map pi-gen's ARCH to the names install.sh expects (it accepts the same
# arm64/armhf enum directly).
case "${ARCH}" in
    arm64|armhf) : ;;
    *) echo "ERROR: stage-05 build does not support ARCH='${ARCH:-unset}'" >&2; exit 1 ;;
esac

WEBCONFIG_BUILD_DIR="${ROOTFS_DIR}/usr/local/src/airplanes-webconfig-build"

rm -rf "${WEBCONFIG_BUILD_DIR}"
install -d -m 755 "${WEBCONFIG_BUILD_DIR}"
git -C "${WEBCONFIG_BUILD_DIR}" init -q
git -C "${WEBCONFIG_BUILD_DIR}" remote add origin "${AIRPLANES_WEBCONFIG_REPO}"
git -C "${WEBCONFIG_BUILD_DIR}" fetch --depth 1 origin "${AIRPLANES_WEBCONFIG_BRANCH}"
git -C "${WEBCONFIG_BUILD_DIR}" checkout -q -B "${AIRPLANES_WEBCONFIG_BRANCH}" FETCH_HEAD

# Record the actual commit baked into the image so the build manifest and
# /health (after install) agree about which release this image carries.
install -d -m 755 "${ROOTFS_DIR}/etc/airplanes"
git -C "${WEBCONFIG_BUILD_DIR}" rev-parse HEAD > "${ROOTFS_DIR}/etc/airplanes/.build-webconfig-sha"

# Hand off to install.sh in build-mode. install.sh exports its own usage of
# ROOTFS_DIR and ARCH and does the network fetch, checksum, manifest
# cross-check, atomic install, and rootfs tarball extraction.
export AIRPLANES_BUILD_MODE=1
bash "${WEBCONFIG_BUILD_DIR}/install.sh" --build-mode

# Install the files that stay image-owned (not in image-webconfig's release
# payload). pi-gen does not auto-copy stage files/; every stage's 00-run.sh
# is responsible for laying them down. These two are device-wide infra
# (lighttpd routing shared with tar1090/graphs1090, tmpfiles lock dir
# shared with feed) and not webconfig-version-specific.
install -D -m 0644 files/etc/lighttpd/conf-available/40-airplanes-webconfig.conf \
    "${ROOTFS_DIR}/etc/lighttpd/conf-available/40-airplanes-webconfig.conf"
install -D -m 0644 files/usr/lib/tmpfiles.d/airplanes-webconfig.conf \
    "${ROOTFS_DIR}/usr/lib/tmpfiles.d/airplanes-webconfig.conf"
