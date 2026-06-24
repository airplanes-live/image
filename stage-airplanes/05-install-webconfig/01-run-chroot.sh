#!/bin/bash
# pi-gen invokes via `bash 01-run-chroot.sh` so shebang flags are ignored;
# explicit set -e is needed.
set -e

export PATH="/usr/local/sbin:${PATH}"

# Create the system user webconfig runs as. --group keeps the primary group
# matched to the username; --no-create-home avoids a /home entry for a
# non-interactive service account.
adduser --system --no-create-home --group airplanes-webconfig

# Create the system user the third-party aggregator units run as. The
# overlay-shipped airplanes-aggregator@<id>.service template (enabled
# per-instance by apl-aggregator when a user opts in) declares
# User=airplanes-aggregator and runs vendor feeder code (e.g. fr24feed) under
# this unprivileged account, never root. Its StateDirectory= provisions the
# account-owned /var/lib/airplanes/aggregators/state at start; the root-owned
# install root and shared dirs are created below.
# Mirrored on the overlay self-update path by runtime-overlay migration 0001.
adduser --system --no-create-home --group airplanes-aggregator

# Shared first-party state root. Created root:root 0755 here so every
# per-service subdir below — and the runtime/aggregator dirs other stages and
# the overlay create — nests under a parent we own, never an account-owned one.
install -d -m 0755 /var/lib/airplanes

# webconfig daemon state (account-owned, 0700). The overlay rootfs ships only
# the files webconfig owns at install time, not these state directories.
install -d -m 0700 -o airplanes-webconfig -g airplanes-webconfig /var/lib/airplanes/webconfig
install -d -m 0700 -o airplanes-webconfig -g airplanes-webconfig /etc/airplanes/webconfig
# Upgrade-state marker dir written by the runtime-overlay update path. Root-owned
# (0755) and deliberately a sibling of webconfig/, not a child: the unprivileged
# daemon reads the marker but must not be able to forge it, and it has to survive
# independently of the account-owned state dir.
install -d -m 0755 /var/lib/airplanes/webconfig-upgrade

# Aggregator install root for the on-demand vendor binaries (e.g. fr24feed).
# Root-owned (0755) and OUTSIDE the airplanes-aggregator account's
# StateDirectory (/var/lib/airplanes/aggregators/state, provisioned per-instance
# by airplanes-aggregator@.service) so the unprivileged account execs binaries
# it cannot replace.
install -d -m 0755 /var/lib/airplanes/aggregators
install -d -m 0755 /var/lib/airplanes/aggregators/bin

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

# video: /dev/vcio access for the hardware tile's vcgencmd probes. The unit
# declares SupplementaryGroups=video so add the user to it when the group
# exists on this image (it does on Raspberry Pi OS).
if getent group video >/dev/null; then
	adduser airplanes-webconfig video || true
fi

# Enable mod_proxy via lighttpd's helper (handles dedup if another snippet
# already loaded it) and link our snippet into conf-enabled. The conf-available
# snippet itself is overlay-owned (a managed_paths symlink laid down by stage
# 02); conf-enabled activation stays image-owned, mirroring the 88-tar1090 /
# 89-airplanes-978 hops in stage 02.
lighttpd-enable-mod proxy
ln -sfn /etc/lighttpd/conf-available/40-airplanes-webconfig.conf \
	/etc/lighttpd/conf-enabled/40-airplanes-webconfig.conf

# Verify the merged config parses now (catches snippet bugs at build time).
lighttpd -tt -f /etc/lighttpd/lighttpd.conf >/dev/null
