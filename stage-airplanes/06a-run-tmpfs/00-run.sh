#!/bin/bash -e

# Lay down the resize script + its systemd unit + the /run/collectd
# mount unit. Both units are enabled via the chroot step (next file)
# so systemctl-stub captures the operation.
install -d -m 755 "${ROOTFS_DIR}/usr/local/lib/airplanes"
install -m 755 files/usr/local/lib/airplanes/run-resize.sh \
    "${ROOTFS_DIR}/usr/local/lib/airplanes/run-resize.sh"

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system"
install -m 644 files/etc/systemd/system/airplanes-run-resize.service \
    "${ROOTFS_DIR}/etc/systemd/system/airplanes-run-resize.service"
install -m 644 files/etc/systemd/system/run-collectd.mount \
    "${ROOTFS_DIR}/etc/systemd/system/run-collectd.mount"

# Pin a 128 MiB floor on /run via fstab. systemd-remount-fs.service
# applies this before local-fs.target, which is before the resize
# service bumps further on larger-RAM Pis. The fstab line is the
# guaranteed safety net: even if the unit fails to start, the
# smallest supported target (Pi Zero 2W) still gets enough headroom
# for the webconfig self-update's 16 MiB reload buffer.
#
# Marker-gated for idempotency under pi-gen modes that re-run a
# stage against an existing rootfs. If an unmarked /run line exists
# (operator override, vendor pre-bake) we refuse rather than append
# a duplicate that could collide at remount.
fstab="${ROOTFS_DIR}/etc/fstab"
marker='# airplanes-live: /run floor'
if grep -q "${marker}" "${fstab}"; then
    echo "06a-run-tmpfs: /etc/fstab already carries the /run floor; skip append" >&2
elif awk '{ if ($1 !~ /^#/ && $2 == "/run") exit 0 } END { exit 1 }' "${fstab}"; then
    echo "ERROR: ${fstab} already contains a /run entry without our marker — refusing to append a conflicting line" >&2
    exit 1
else
    cat >> "${fstab}" <<EOF

${marker}
tmpfs  /run  tmpfs  nosuid,nodev,noexec,relatime,size=128M,mode=755  0  0
EOF
fi
