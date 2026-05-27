#!/bin/bash -e

# Install render-status + ASCII assets + motd hook image-owned UNLESS the
# runtime-overlay path has already placed them. Presence-of-symlink-target
# is the discriminator rather than an env flag, so any stage enumeration
# that runs 06b without first running 02-install-runtime-overlay (e.g.
# feed-overlay-smoke's docker container, which iterates stages without
# honouring SKIP files) still gets a working dashboard. Under the new
# path, 02-install-runtime-overlay already laid a symlink under
# current/lib/airplanes/render-status before 06b runs, so this block is a
# no-op. Dashboard service unit and getty override below stay unconditional
# — they're version-stable infrastructure that doesn't need runtime updates.
# -L checks for a symlink regardless of target validity (the overlay symlink
# uses an absolute /opt/airplanes-runtime/... target that only resolves in
# the live rootfs, not in chroot-time tests). -e covers a regular file
# placed by some other stage. Either present → 06b is a no-op.
if [[ ! -L "${ROOTFS_DIR}/usr/local/lib/airplanes/render-status" \
      && ! -e "${ROOTFS_DIR}/usr/local/lib/airplanes/render-status" ]]; then
	install -D -m 755 "${BASE_DIR:-.}/runtime-overlay/src/lib/airplanes/render-status" \
	    "${ROOTFS_DIR}/usr/local/lib/airplanes/render-status"

	install -D -m 644 "${BASE_DIR:-.}/runtime-overlay/src/share/airplanes/logo.txt" \
	    "${ROOTFS_DIR}/usr/local/share/airplanes/logo.txt"
	install -D -m 644 "${BASE_DIR:-.}/runtime-overlay/src/share/airplanes/banner.txt" \
	    "${ROOTFS_DIR}/usr/local/share/airplanes/banner.txt"
	install -D -m 644 "${BASE_DIR:-.}/runtime-overlay/src/share/airplanes/banner-narrow.txt" \
	    "${ROOTFS_DIR}/usr/local/share/airplanes/banner-narrow.txt"
	install -D -m 644 "${BASE_DIR:-.}/runtime-overlay/src/share/airplanes/icon.txt" \
	    "${ROOTFS_DIR}/usr/local/share/airplanes/icon.txt"

	install -D -m 755 "${BASE_DIR:-.}/runtime-overlay/src/etc/update-motd.d/10-airplanes-status" \
	    "${ROOTFS_DIR}/etc/update-motd.d/10-airplanes-status"
fi

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system"
install -m 644 files/etc/systemd/system/airplanes-dashboard.service \
    "${ROOTFS_DIR}/etc/systemd/system/airplanes-dashboard.service"

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d"
install -m 644 files/etc/systemd/system/getty@tty1.service.d/override.conf \
    "${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d/override.conf"
