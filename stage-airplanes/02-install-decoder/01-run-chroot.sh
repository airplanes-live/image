#!/bin/bash -e

# Stub catches systemctl daemon-reload / start / restart / is-active that some
# install scripts call directly; legitimate enable/disable/mask pass through.
export PATH="/usr/local/sbin:${PATH}"

# 1. Compile wiedehopf readsb. -j2 is QEMU-safe (matches feed convention; -j$(nproc)
# OOMs on armhf qemu-user emulation).
cd /usr/local/src/airplanes-readsb-build
if dpkg --print-architecture | grep -qs armhf; then
	make -j2 AIRCRAFT_HASH_BITS=12 RTLSDR=yes \
		OPTIMIZE="-O2 -marm -mcpu=arm1176jzf-s -mfpu=vfp"
else
	make -j2 AIRCRAFT_HASH_BITS=12 RTLSDR=yes
fi
install -m 0755 readsb /usr/bin/readsb
install -m 0755 viewadsb /usr/bin/viewadsb
# Hardlink: airplanes-978 is the same readsb binary, second name. Saves disk.
ln -f /usr/bin/readsb /usr/bin/airplanes-978

# 2. Compile flightaware dump978. Build only the dump978-fa target; skyaware978
# is FA's standalone dashboard which we don't ship.
cd /usr/local/src/airplanes-dump978-build
make -j2 dump978-fa
install -m 0755 dump978-fa /usr/bin/dump978-fa
# Defensive build-time check for unresolved boost/soapy/usb libs.
if ldd /usr/bin/dump978-fa | grep -q 'not found'; then
	echo "dump978-fa has unresolved shared libraries:" >&2
	ldd /usr/bin/dump978-fa | grep 'not found' >&2
	exit 1
fi

# 3. readsb user (idempotent under repeated overlay-smoke runs / CONTINUE=1).
if ! getent passwd readsb >/dev/null; then
	adduser --system --home /usr/local/share/readsb --no-create-home --quiet readsb
fi
adduser readsb plugdev || true
adduser readsb dialout || true

# 4. Enable readsb. 978 services stay disabled (first-run enables on DUMP978=yes).
systemctl enable readsb.service
