#!/bin/bash -e

# Reap any chroot-rooted processes still running from earlier stages
# before pi-gen's per-stage cleanup tries to unmount the bind mounts.
# graphs1090's install.sh runs `collectd 2>&1 | grep …` to detect the
# python version, and per upstream's own comment that invocation can
# leave a daemonized collectd running. Under cross-arch pi-gen builds
# the chroot binary runs through qemu-aarch64 via binfmt_misc, so the
# leaked process is named `qemu-aarch64` with cmdline
# `/usr/bin/qemu-aarch64 /usr/sbin/collectd collectd`. The kill needs
# to run from the host context (where /proc/$pid/root resolves to the
# chroot rootfs absolute path) AND late enough for collectd to have
# finished its daemonization fork — stage 04/02 was too early.
for pid_dir in /proc/[0-9]*; do
    pid="${pid_dir##*/}"
    pid_root="$(readlink "$pid_dir/root" 2>/dev/null || true)"
    [[ -z "$pid_root" || "$pid_root" == "/" ]] && continue
    [[ "$pid_root" != "${ROOTFS_DIR%/}" ]] && continue
    kill -9 "$pid" 2>/dev/null || true
done

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
