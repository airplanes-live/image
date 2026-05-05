#!/bin/bash -e

# Force cloud-init off the raspberry_pi_os Distro and onto plain debian.
# Rationale lives in the dropped file's header — search for the symptom
# ("setup_user_keys never runs") to find it. This is a defence-in-depth
# pair with 03-run.sh's userconfig.service mask: 03 stops the systemd
# first-boot wizard, this stops cloud-init from invoking the same
# userconf-pi binary internally.

install -d -m 755 "${ROOTFS_DIR}/etc/cloud/cloud.cfg.d"
install -m 644 files/etc/cloud/cloud.cfg.d/99-airplanes-distro-debian.cfg \
	"${ROOTFS_DIR}/etc/cloud/cloud.cfg.d/99-airplanes-distro-debian.cfg"
