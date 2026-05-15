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

# Lock down the sudoers snippets (0440 root:root is what visudo accepts) and
# verify each parses before the stage exits. Both files ship in the
# image-webconfig release tarball with mode 0440 already, but the chmod
# here is a belt-and-braces defence against a future tar pipeline writing
# them at 0644.
for f in 010_airplanes-webconfig 011_airplanes-webconfig-update; do
    chmod 0440 /etc/sudoers.d/"$f"
    chown root:root /etc/sudoers.d/"$f"
    visudo -cf /etc/sudoers.d/"$f"
done

# /api/log/{unit} streams journalctl as the webconfig user. Adding it to
# systemd-journal grants read access to the system journal without sudo.
adduser airplanes-webconfig systemd-journal

# Add airplanes-webconfig to the airplanes-feed group so the reveal handler
# can read /etc/airplanes/feeder-claim-secret directly via group permissions
# (mode 0640 group=airplanes-feed, set by feed/scripts/apl-feed/common.sh's
# write_secret_file). Without this, the reveal would have to escalate via
# sudo to a user that can read the file. Stage 01 ran feed install, which
# creates the airplanes-feed user + group, so they exist by stage 05.
#
# Membership in airplanes-feed grants read access to the claim secret;
# this is the only legitimate consumer added here. Adding other accounts
# would broaden the read surface — don't.
adduser airplanes-webconfig airplanes-feed

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
