#!/bin/bash -e

# Keep the kernel DVB-T / V4L2-SDR drivers off RTL2832U SDR dongles. readsb
# and dump978-fa open the dongles from userspace (librtlsdr / SoapyRTLSDR via
# libusb) and need no kernel SDR module; left unblacklisted, dvb_usb_rtl28xxu
# binds a dongle at boot and runs an IR-remote poller, which races librtlsdr's
# open-time detach and is unreliable with two SDRs. Shipped as a real rootfs
# file (not via the runtime overlay) so it can never dangle on an overlay
# update/rollback and is present for udev coldplug on first boot. The dropped
# file's header documents which modules are listed and why.
install -D -m 0644 files/etc/modprobe.d/airplanes-rtlsdr-blacklist.conf \
	"${ROOTFS_DIR}/etc/modprobe.d/airplanes-rtlsdr-blacklist.conf"
