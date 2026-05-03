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
