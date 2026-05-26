#!/bin/bash
# Explicit `set -e` (not just shebang) — pi-gen invokes via `on_chroot <
# 01-run-chroot.sh`, which feeds the body to bash inside the chroot and
# ignores the shebang's flags.
set -e

# Stub catches systemctl daemon-reload / start / restart / is-active that some
# install scripts call directly; legitimate enable/disable/mask pass through.
export PATH="/usr/local/sbin:${PATH}"

# readsb service account.
if ! getent passwd readsb >/dev/null; then
	adduser --system --group --home /usr/local/share/readsb --no-create-home --quiet readsb
fi
adduser readsb plugdev || true
adduser readsb dialout || true

# tar1090 service account. tar1090.service runs as User=tar1090; the
# overlay ships the unit but the account must exist on the image or
# systemd fails the unit with 217/USER before ExecStart runs and (being
# Restart=always) auto-restart-loops forever. The legacy tar1090
# installer created it; the overlay cutover must keep doing so. Flags
# match upstream tar1090 install.sh: `--system` without `--group` lands
# the user in the `nogroup` group (do not assume tar1090:tar1090
# ownership downstream).
if ! getent passwd tar1090 >/dev/null; then
	adduser --system --home /usr/local/share/tar1090 --no-create-home --quiet tar1090
fi

# readsb writes heatmap + coverage history here (--write-globe-history);
# tar1090 reads it.
install -d -m 0755 -o readsb -g readsb /var/globe_history

# Seed mutable config files the runtime overlay's reconcile services
# expect to find on first boot. The release tarball ships their package
# defaults under share/tar1090/example_config_dont_edit and
# etc/collectd/collectd.conf; these are declared mutable_paths so on
# subsequent updates the on-device installer backs them up before any
# overlay-driven mutation and respects user edits via if_key_unset
# migrations. At image-build time the files do not exist yet — copy the
# packaged defaults across.
if [[ ! -e /etc/default/tar1090 ]]; then
	install -d -m 0755 /etc/default
	install -m 0644 /opt/airplanes-runtime/current/share/tar1090/example_config_dont_edit \
		/etc/default/tar1090
fi
if [[ ! -e /etc/collectd/collectd.conf ]]; then
	install -d -m 0755 /etc/collectd
	install -m 0644 /opt/airplanes-runtime/current/etc/collectd/collectd.conf \
		/etc/collectd/collectd.conf
fi
if [[ ! -e /etc/cron.d/collectd_to_disk \
		&& -e /opt/airplanes-runtime/current/etc/cron.d/collectd_to_disk ]]; then
	install -d -m 0755 /etc/cron.d
	install -m 0644 /opt/airplanes-runtime/current/etc/cron.d/collectd_to_disk \
		/etc/cron.d/collectd_to_disk
fi

# Enable the unit set the runtime overlay manifest declares. The list is read
# DYNAMICALLY from the active release manifest's systemd.enable array — the
# manifest is the single source of truth so a future release that adds a unit
# does not require an image rebuild. collectd.service is apt-managed and the
# unit ships with collectd-core; the others are overlay-owned via the
# /etc/systemd/system/ → /opt/airplanes-runtime/current/ symlinks the
# host-side stage laid down. UAT services self-disable cleanly when UAT_INPUT
# is empty in /etc/airplanes/feed.env (wrappers publish a disabled decision
# file and sleep so the unit stays active).
RUNTIME_MANIFEST=/opt/airplanes-runtime/current/manifest.json
if [[ ! -f "$RUNTIME_MANIFEST" ]]; then
	echo "ERROR: runtime overlay manifest not found at $RUNTIME_MANIFEST" >&2
	exit 1
fi
mapfile -t ENABLE_UNITS < <(jq -r '.systemd.enable[]?' "$RUNTIME_MANIFEST")
if (( ${#ENABLE_UNITS[@]} == 0 )); then
	echo "ERROR: runtime overlay manifest declares no units to enable" >&2
	exit 1
fi
systemctl enable "${ENABLE_UNITS[@]}"

# The boot-recovery unit is image-owned (it must survive a broken overlay),
# so it is NOT in the manifest's enable set. Enable it here explicitly.
systemctl enable airplanes-runtime-update-recover.service

# lighttpd conf-enabled stays image-owned; conf-available is overlay-owned
# via the managed_paths symlinks. The two-hop chain (conf-enabled → image
# absolute path → overlay current) is asserted in extra-probe.sh.
ln -sfn /opt/airplanes-runtime/current/etc/lighttpd/conf-available/89-airplanes-978.conf \
	/etc/lighttpd/conf-enabled/89-airplanes-978.conf
ln -sfn /opt/airplanes-runtime/current/etc/lighttpd/conf-available/88-tar1090.conf \
	/etc/lighttpd/conf-enabled/88-tar1090.conf
ln -sfn /opt/airplanes-runtime/current/etc/lighttpd/conf-available/88-graphs1090.conf \
	/etc/lighttpd/conf-enabled/88-graphs1090.conf
