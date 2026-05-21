#!/bin/bash -e

# Host-side stage: invoke runtime-overlay/install.sh --build-mode against the
# concrete release tag pinned in config-{dev,stable}. install.sh downloads,
# verifies (sha256 + minisign), extracts the release tarball under
# ${ROOTFS_DIR}/opt/airplanes-runtime/releases/v<version>/, flips the
# `current` symlink, relinks the /usr/bin/{readsb,airplanes-978,dump978-fa}
# decoder binaries, and applies every managed_paths entry from the release
# manifest (the FHS stable-path symlink set into /opt/airplanes-runtime/current/).
#
# The companion chroot stage handles the readsb service account, /var/globe_history,
# systemctl enable, and the conf-enabled lighttpd hop — everything that has to
# run inside the target rootfs.

: "${AIRPLANES_RUNTIME_OVERLAY_TAG:?must be set by config-stable/dev}"
: "${ARCH:?must be set by pi-gen}"
: "${ROOTFS_DIR:?must be set by pi-gen}"
: "${BASE_DIR:?must be set by pi-gen}"

# Copy the runtime-overlay source tree into a scratch dir outside the rootfs
# so install.sh's $_self_dir resolution does not point at a path inside the
# staging chroot. We are airplanes-live/image — runtime-overlay/ in BASE_DIR
# is the same source the runtime-release.yml workflow consumed to build the
# pinned release. The scratch copy is unsigned/no-.git, so install.sh's
# build-mode commit_sha cross-check skips cleanly; the
# manifest-version ↔ release-tag check still pins tag↔manifest identity.
RUNTIME_OVERLAY_SRC="${ROOTFS_DIR}/var/tmp/airplanes-runtime-overlay-src"
rm -rf -- "$RUNTIME_OVERLAY_SRC"
install -d -m 755 "$(dirname "$RUNTIME_OVERLAY_SRC")"
cp -a "${BASE_DIR}/runtime-overlay" "$RUNTIME_OVERLAY_SRC"
# Drop any stray .git the cp may have brought along (it shouldn't — we copy
# the subdir, not the repo — but belt-and-braces in case of submodule oddities).
rm -rf -- "$RUNTIME_OVERLAY_SRC/.git"

# Pubkey path override. install-common.sh defaults to
# /usr/share/airplanes/runtime-release.pub which lives in the *target rootfs*,
# not on the host where install.sh runs in build mode. Point it at the
# in-repo copy that stage 00-prep installs into the rootfs from the same
# file. The two paths are byte-identical (same source file on disk). Honour
# a pre-set AIRPLANES_RUNTIME_MINISIGN_PUBKEY so the bats fixture (which
# signs against a throwaway key) can swap it out without forking the stage.
PUBKEY_HOST_PATH="${AIRPLANES_RUNTIME_MINISIGN_PUBKEY:-${BASE_DIR}/stage-airplanes/00-prep/files/usr/share/airplanes/runtime-release.pub}"
if [[ ! -r "$PUBKEY_HOST_PATH" ]]; then
	echo "ERROR: runtime-release pubkey missing at $PUBKEY_HOST_PATH" >&2
	exit 1
fi

# Resolve the runtime-overlay source SHA for the build manifest. BASE_DIR is
# the image repo HEAD; runtime-overlay lives inside it.
install -d -m 755 "${ROOTFS_DIR}/etc/airplanes"
{
	if sha="$(git -C "${BASE_DIR}" rev-parse HEAD 2>/dev/null)" && [[ -n "$sha" ]]; then
		printf '%s\n' "$sha"
	else
		printf 'unknown\n'
	fi
} > "${ROOTFS_DIR}/etc/airplanes/.build-runtime-overlay-sha"

env \
	AIRPLANES_BUILD_MODE=1 \
	ROOTFS_DIR="$ROOTFS_DIR" \
	ARCH="$ARCH" \
	AIRPLANES_RUNTIME_OVERLAY_TAG="$AIRPLANES_RUNTIME_OVERLAY_TAG" \
	AIRPLANES_RUNTIME_MINISIGN_PUBKEY="$PUBKEY_HOST_PATH" \
	bash "$RUNTIME_OVERLAY_SRC/install.sh" --build-mode

rm -rf -- "$RUNTIME_OVERLAY_SRC"
