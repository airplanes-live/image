#!/bin/bash
# pi-gen invokes via `bash 01-run-chroot.sh` so shebang flags are ignored;
# explicit `set -e` is needed.
set -e

export PATH="/usr/local/sbin:${PATH}"

# Run tar1090's install.sh with our pre-staged source as $4 (upstream-supported
# "use local git source" hook — bypasses network fetch of tar1090 itself).
# tar1090-db is fetched separately by upstream getGIT but our 00-run.sh
# repointed its origin at /dev/null so the re-fetch fails and the pinned SHA
# remains in place.
cd /usr/local/src/airplanes-tar1090-build
bash install.sh /run/readsb tar1090 /usr/local/share/tar1090 /usr/local/src/airplanes-tar1090-build

# Wire 978 visualization. tar1090's default URL_978 already points at
# http://127.0.0.1/skyaware978; we ship a lighttpd alias that maps it to our
# /run/airplanes-978/ JSON dir.
sed -i 's/^ENABLE_978=.*/ENABLE_978=yes/' /etc/default/tar1090
ln -sfn /etc/lighttpd/conf-available/89-airplanes-978.conf \
	/etc/lighttpd/conf-enabled/89-airplanes-978.conf

# Drop tar1090's :8504 alternative listener; we only expose tar1090 via :80.
rm -f /etc/lighttpd/conf-enabled/95-tar1090-otherport.conf
