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
# /run/airplanes-978/ JSON dir. ENABLE_978 in /etc/default/tar1090 stays at
# upstream default "no" — flipping it on every image meant tar1090's main
# loop spammed "978.json: No such file or directory" every iteration on
# the common case of feeders without a 978 SDR. The
# airplanes-tar1090-uat-sync.path watches /run/airplanes-978/state and
# /run/dump978-fa/state and toggles ENABLE_978 at runtime instead.
ln -sfn /etc/lighttpd/conf-available/89-airplanes-978.conf \
	/etc/lighttpd/conf-enabled/89-airplanes-978.conf
systemctl enable airplanes-tar1090-uat-sync.service airplanes-tar1090-uat-sync.path

# Drop tar1090's :8504 alternative listener; we only expose tar1090 via :80.
rm -f /etc/lighttpd/conf-enabled/95-tar1090-otherport.conf
