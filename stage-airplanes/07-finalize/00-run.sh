#!/bin/bash -e

# Verify the systemctl shim caught everything install.sh tried to do, then
# remove all build-only intercept state. Run check-stub-log.sh before the
# cleanup wipes the log it is asserting against.
bash "${BASE_DIR}/scripts/check-stub-log.sh" "${ROOTFS_DIR}"

# Generate /etc/airplanes/build-manifest.json. Must come AFTER check-stub-log.sh
# (which writes the fingerprint the manifest folds in) and BEFORE the rm -f
# cleanup so the manifest is part of the shipped rootfs.
bash "${BASE_DIR}/scripts/manifest-generator.sh" "${ROOTFS_DIR}"

rm -f "${ROOTFS_DIR}/usr/sbin/policy-rc.d"
rm -f "${ROOTFS_DIR}/usr/local/sbin/airplanes-systemctl-stub"
rm -f "${ROOTFS_DIR}/usr/local/sbin/systemctl"
rm -f "${ROOTFS_DIR}/usr/local/sbin/service"
rm -f "${ROOTFS_DIR}/usr/local/sbin/deb-systemd-invoke"
rm -f "${ROOTFS_DIR}/var/log/airplanes-systemctl-stub.log"

# Defensive assertions: the shipped image must not carry build-only state.
for path in \
	"${ROOTFS_DIR}/usr/sbin/policy-rc.d" \
	"${ROOTFS_DIR}/usr/local/sbin/airplanes-systemctl-stub" \
	"${ROOTFS_DIR}/usr/local/sbin/systemctl" \
	"${ROOTFS_DIR}/usr/local/sbin/service" \
	"${ROOTFS_DIR}/usr/local/sbin/deb-systemd-invoke" \
	"${ROOTFS_DIR}/var/log/airplanes-systemctl-stub.log"
do
	if [[ -e "$path" ]]; then
		echo "ERROR: stage 07 left build-only state at $path" >&2
		exit 1
	fi
done
