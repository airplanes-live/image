#!/bin/bash
# Explicit `set -e` (not just shebang) — pi-gen invokes via `bash 01-run-chroot.sh`,
# which ignores the shebang's flags.
set -e

# Stub catches systemctl daemon-reload / start / restart / is-active that some
# install scripts call directly; legitimate enable/disable/mask pass through.
export PATH="/usr/local/sbin:${PATH}"

# armhf qemu-user emulation OOMs above -j2; native arm64 handles -j$(nproc).
if dpkg --print-architecture | grep -qs armhf; then
	build_jobs=2
else
	build_jobs="$(nproc)"
fi

# 1. Compile wiedehopf readsb.
cd /usr/local/src/airplanes-readsb-build
if dpkg --print-architecture | grep -qs armhf; then
	make -j"$build_jobs" AIRCRAFT_HASH_BITS=12 RTLSDR=yes \
		OPTIMIZE="-O2 -marm -mcpu=arm1176jzf-s -mfpu=vfp"
else
	make -j"$build_jobs" AIRCRAFT_HASH_BITS=12 RTLSDR=yes
fi
install -m 0755 readsb /usr/bin/readsb
install -m 0755 viewadsb /usr/bin/viewadsb
# Hardlink: airplanes-978 is the same readsb binary, second name. Saves disk.
ln -f /usr/bin/readsb /usr/bin/airplanes-978

# 2. Compile flightaware dump978. Build only the dump978-fa target; skyaware978
# is FA's standalone dashboard which we don't ship.
cd /usr/local/src/airplanes-dump978-build
make -j"$build_jobs" dump978-fa
install -m 0755 dump978-fa /usr/bin/dump978-fa
# Defensive build-time check for unresolved boost/soapy/usb libs.
if ldd /usr/bin/dump978-fa | grep -q 'not found'; then
	echo "dump978-fa has unresolved shared libraries:" >&2
	ldd /usr/bin/dump978-fa | grep 'not found' >&2
	exit 1
fi

# 3. readsb user + same-named group (idempotent under repeated overlay-smoke
# runs / CONTINUE=1). `--group` is required so /var/globe_history can be
# chgrp'd to readsb below.
if ! getent passwd readsb >/dev/null; then
	adduser --system --group --home /usr/local/share/readsb --no-create-home --quiet readsb
fi
adduser readsb plugdev || true
adduser readsb dialout || true

# readsb writes heatmap + coverage history here (--write-globe-history); tar1090 reads it.
install -d -m 0755 -o readsb -g readsb /var/globe_history

# 4. Enable services. 978 units always-enabled and self-disable via exit 64
# when UAT_INPUT is empty/invalid (parallel to airplanes-mlat); first-run no
# longer flips them based on DUMP978=yes — it translates the boot-config knob
# into UAT_INPUT and the wrappers decide.
systemctl enable readsb.service
systemctl enable dump978-fa.service airplanes-978.service
