#!/bin/bash
# pi-gen invokes via `bash 01-run-chroot.sh` so shebang flags are ignored;
# explicit set -e is needed.
set -e

export PATH="/usr/local/sbin:${PATH}"

# Create the system user webconfig runs as. --group keeps the primary group
# matched to the username; --no-create-home avoids a /home entry for a
# non-interactive service account.
adduser --system --no-create-home --group airplanes-webconfig

# Per-user state dirs were created with mode 0700 in 00-run.sh; assign owner.
chown -R airplanes-webconfig:airplanes-webconfig /var/lib/airplanes-webconfig
chown -R airplanes-webconfig:airplanes-webconfig /etc/airplanes/webconfig

# Enable mod_proxy via lighttpd's helper (handles dedup if another snippet
# already loaded it) and link our snippet into conf-enabled.
lighttpd-enable-mod proxy
ln -sfn /etc/lighttpd/conf-available/40-airplanes-webconfig.conf \
	/etc/lighttpd/conf-enabled/40-airplanes-webconfig.conf

# Verify the merged config parses now (catches snippet bugs at build time).
lighttpd -tt -f /etc/lighttpd/lighttpd.conf >/dev/null

# Enable webconfig.service. The stub catches `enable` and forwards to the real
# systemctl, which is a symlink edit and works inside the chroot. The reset
# oneshot is enabled with WantedBy=airplanes-webconfig.service so enabling
# webconfig pulls in the reset wants symlink as well.
systemctl enable airplanes-webconfig-reset.service
systemctl enable airplanes-webconfig.service
