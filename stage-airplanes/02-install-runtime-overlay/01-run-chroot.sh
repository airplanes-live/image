#!/bin/bash
# Explicit `set -e` (not just shebang) — pi-gen invokes via `on_chroot <
# 01-run-chroot.sh`, which feeds the body to bash inside the chroot and
# ignores the shebang's flags.
set -e

# Stub catches systemctl daemon-reload / start / restart / is-active that some
# install scripts call directly; legitimate enable/disable/mask pass through.
export PATH="/usr/local/sbin:${PATH}"

# readsb service account. Flags preserved verbatim from the legacy
# 02-install-decoder stage so the on-disk uid/gid/home/shell shape is
# byte-identical regardless of which install path produced the image.
if ! getent passwd readsb >/dev/null; then
	adduser --system --group --home /usr/local/share/readsb --no-create-home --quiet readsb
fi
adduser readsb plugdev || true
adduser readsb dialout || true

# readsb writes heatmap + coverage history here (--write-globe-history);
# tar1090 reads it.
install -d -m 0755 -o readsb -g readsb /var/globe_history

# Enable the unit set the runtime overlay manifest declares. collectd.service
# is apt-managed and the unit ships with collectd-core; the others are now
# overlay-owned via the /etc/systemd/system/ → /opt/airplanes-runtime/current/
# symlinks the host-side stage laid down. UAT services self-disable cleanly
# when UAT_INPUT is empty in /etc/airplanes/feed.env (wrappers publish a
# disabled decision file and sleep so the unit stays active).
systemctl enable \
	readsb.service \
	airplanes-978.service \
	dump978-fa.service \
	airplanes-tar1090-uat-sync.service \
	airplanes-tar1090-uat-sync.path \
	tar1090.service \
	graphs1090.service \
	collectd.service \
	airplanes-runtime-update-recover.service

# lighttpd conf-enabled stays image-owned; conf-available is overlay-owned
# via the managed_paths symlinks. The two-hop chain (conf-enabled → image
# absolute path → overlay current) is asserted in extra-probe.sh.
ln -sfn /opt/airplanes-runtime/current/etc/lighttpd/conf-available/89-airplanes-978.conf \
	/etc/lighttpd/conf-enabled/89-airplanes-978.conf
ln -sfn /opt/airplanes-runtime/current/etc/lighttpd/conf-available/88-tar1090.conf \
	/etc/lighttpd/conf-enabled/88-tar1090.conf
ln -sfn /opt/airplanes-runtime/current/etc/lighttpd/conf-available/88-graphs1090.conf \
	/etc/lighttpd/conf-enabled/88-graphs1090.conf
