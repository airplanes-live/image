#!/bin/bash
# Explicit `set -e` (not just the shebang) — pi-gen sources this via
# `run_stage`, and the bats harness invokes it as `bash 00-run.sh`; both
# ignore the shebang's flags, so a failure in install.sh must abort here
# rather than fall through to the trailing cleanup with a 0 exit.
set -e

# Host-side stage: invoke runtime-overlay/install.sh --build-mode against either
# the signed runtime assets produced earlier in CI
# (AIRPLANES_RUNTIME_RELEASE_ASSET_DIR) or the current channel's published
# product release. install.sh verifies (sha256 + minisign), extracts the tarball under
# ${ROOTFS_DIR}/opt/airplanes/releases/v<version>/, flips the
# `current` symlink, relinks the /usr/bin/{readsb,airplanes-978,dump978-fa}
# decoder binaries, and applies every managed_paths entry from the release
# manifest (the FHS stable-path symlink set into /opt/airplanes/current/).
#
# The companion chroot stage handles the readsb service account, /var/globe_history,
# systemctl enable, and the conf-enabled lighttpd hop — everything that has to
# run inside the target rootfs.

: "${ARCH:?must be set by pi-gen}"
: "${ROOTFS_DIR:?must be set by pi-gen}"
: "${BASE_DIR:?must be set by pi-gen}"

# Image-owned recovery files. The boot-recovery shim and its unit must
# survive a completely broken overlay, so they are installed directly into
# the image (NOT through the overlay's managed_paths). Copy them in before
# the overlay install so the unit's ConditionPathExists target exists.
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -d -m 755 "${ROOTFS_DIR}/opt/airplanes/libexec"
install -m 0755 \
	"${STAGE_DIR}/files/opt/airplanes/libexec/recover-shim" \
	"${ROOTFS_DIR}/opt/airplanes/libexec/recover-shim"
install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system"
install -m 0644 \
	"${STAGE_DIR}/files/etc/systemd/system/airplanes-runtime-update-recover.service" \
	"${ROOTFS_DIR}/etc/systemd/system/airplanes-runtime-update-recover.service"
install -d -m 755 "${ROOTFS_DIR}/etc/update-motd.d"
install -m 0755 \
	"${STAGE_DIR}/files/etc/update-motd.d/09-airplanes-recovery-status" \
	"${ROOTFS_DIR}/etc/update-motd.d/09-airplanes-recovery-status"
# State + last-good dirs the shim and updater write into.
install -d -m 755 "${ROOTFS_DIR}/var/lib/airplanes/runtime-upgrade"
install -d -m 755 "${ROOTFS_DIR}/var/lib/airplanes/runtime"

# Copy the runtime-overlay source tree into a scratch dir outside the rootfs
# so install.sh's $_self_dir resolution does not point at a path inside the
# staging chroot. We are airplanes-live/image — runtime-overlay/ in BASE_DIR
# is the same source the product workflow consumed to build the runtime assets
# passed in AIRPLANES_RUNTIME_RELEASE_ASSET_DIR.
#
# Build-mode commit_sha cross-check: install.sh's `git -C "$_self_dir"
# rev-parse HEAD` walks UP from the scratch dir, finding any ancestor .git
# (including the image repo's own under BASE_DIR if the scratch path sits
# inside it). The check then compares the image repo's HEAD to the
# release's manifest commit_sha, which mismatches whenever the PR head
# differs from the pinned-release commit. That's the normal state of any
# PR. Set AIRPLANES_RUNTIME_SKIP_SOURCE_SHA_CHECK=1 to bypass — the
# device installs the release tarball, not the in-tree source, so the
# source-matches-release invariant isn't load-bearing here. Minisign +
# manifest-version still pin tag↔manifest↔tarball.
RUNTIME_OVERLAY_SRC="${ROOTFS_DIR}/var/tmp/airplanes-runtime-overlay-src"
rm -rf -- "$RUNTIME_OVERLAY_SRC"
install -d -m 755 "$(dirname "$RUNTIME_OVERLAY_SRC")"
cp -a "${BASE_DIR}/runtime-overlay" "$RUNTIME_OVERLAY_SRC"
# Drop any stray .git the cp may have brought along (it shouldn't — we copy
# the subdir, not the repo — but belt-and-braces in case of submodule oddities).
rm -rf -- "$RUNTIME_OVERLAY_SRC/.git"

# Pubkey path. install-common.sh defaults to
# /opt/airplanes/libexec/runtime-release.pub which lives in the *target rootfs*,
# not on the host where install.sh runs in build mode. Point it at the
# in-repo copy that stage 00-prep installs into the rootfs from the same
# file (the two paths are byte-identical — same source file on disk).
#
# Test fixtures sign releases with a throwaway key and need an escape hatch.
# Gate that escape hatch behind an explicit opt-in env var so a stray env
# variable in CI cannot silently downgrade verification to a test key.
PUBKEY_HOST_PATH="${BASE_DIR}/stage-airplanes/00-prep/files/opt/airplanes/libexec/runtime-release.pub"
if [[ "${AIRPLANES_RUNTIME_BUILD_TEST_PUBKEY:-0}" == "1" \
		&& -n "${AIRPLANES_RUNTIME_MINISIGN_PUBKEY:-}" ]]; then
	PUBKEY_HOST_PATH="$AIRPLANES_RUNTIME_MINISIGN_PUBKEY"
	echo "stage 02-install-runtime-overlay: TEST pubkey override active: $PUBKEY_HOST_PATH" >&2
fi
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
	CHANNEL="${CHANNEL:-}" \
	AIRPLANES_RUNTIME_OVERLAY_TAG="${AIRPLANES_RUNTIME_OVERLAY_TAG:-}" \
	AIRPLANES_RUNTIME_RELEASE_ASSET_DIR="${AIRPLANES_RUNTIME_RELEASE_ASSET_DIR:-}" \
	AIRPLANES_RUNTIME_MINISIGN_PUBKEY="$PUBKEY_HOST_PATH" \
	AIRPLANES_RUNTIME_SKIP_SOURCE_SHA_CHECK=1 \
	bash "$RUNTIME_OVERLAY_SRC/install.sh" --build-mode

rm -rf -- "$RUNTIME_OVERLAY_SRC"
