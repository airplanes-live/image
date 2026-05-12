#!/bin/bash -e

# Suppress service starts triggered by apt maintainer scripts during chroot
# installs. invoke-rc.d honours an exit-101 policy-rc.d.
install -m 755 files/policy-rc.d "${ROOTFS_DIR}/usr/sbin/policy-rc.d"

# PATH-prepended shim catches direct systemctl/service/deb-systemd-invoke
# invocations from feed/install.sh. Stage 07 removes the stub and symlinks.
install -m 755 "${BASE_DIR}/scripts/systemctl-stub" \
	"${ROOTFS_DIR}/usr/local/sbin/airplanes-systemctl-stub"
ln -sf airplanes-systemctl-stub "${ROOTFS_DIR}/usr/local/sbin/systemctl"
ln -sf airplanes-systemctl-stub "${ROOTFS_DIR}/usr/local/sbin/service"
ln -sf airplanes-systemctl-stub "${ROOTFS_DIR}/usr/local/sbin/deb-systemd-invoke"

install -d -m 755 "${ROOTFS_DIR}/etc/airplanes"

# Record pi-gen HEAD SHA for the build manifest. `-dirty` flags local builds
# with uncommitted changes; CI runners always have clean checkouts.
{
	if sha="$(git -C "${BASE_DIR}" rev-parse HEAD 2>/dev/null)" && [[ -n "$sha" ]]; then
		suffix=""
		git -C "${BASE_DIR}" diff-index --quiet HEAD -- 2>/dev/null || suffix="-dirty"
		printf '%s%s\n' "$sha" "$suffix"
	else
		printf 'unknown\n'
	fi
} > "${ROOTFS_DIR}/etc/airplanes/.build-pi-gen-sha"
