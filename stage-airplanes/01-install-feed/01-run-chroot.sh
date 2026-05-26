#!/bin/bash
# pi-gen invokes via `bash 01-run-chroot.sh` so shebang flags are ignored;
# explicit set -e is needed.
set -e

export PATH="/usr/local/sbin:${PATH}"

# The feeder readsb binary, mlat-client venv, feed scripts, apl-feed CLI, and
# the airplanes-feed / airplanes-mlat systemd units all ship inside the runtime
# overlay (laid down by stage 02 as managed_paths symlinks, enabled dynamically
# from the overlay manifest). Stage 01 retains only the chroot setup that cannot
# be overlay-managed: the airplanes-feed service account + group, and the state
# directory the daemons and claim flow write to.
#
# A private airplanes-feed group lets other service accounts (e.g.
# airplanes-webconfig, added to it in stage 05) read claim-state files
# (mode 0640) without escalating to root. The account is created here so it
# exists before stage 05's group-membership wiring and before first boot starts
# the overlay-shipped airplanes-feed.service.

# Create the airplanes-feed system group + user. Primary group matches the
# username; --no-create-home avoids a /home entry for a non-interactive
# service account. Idempotent guards mirror feed's ensure_airplanes_feed_account.
if ! getent group airplanes-feed >/dev/null 2>&1; then
	addgroup --system airplanes-feed
fi
if ! id -u airplanes-feed >/dev/null 2>&1; then
	adduser --system --ingroup airplanes-feed \
		--home /usr/local/share/airplanes --no-create-home --quiet airplanes-feed
fi

# Pi hardware: the daemon user needs the `video` group so vcgencmd can read
# /dev/vchiq for the diagnostics throttle fields. Add it when the group exists.
if getent group video >/dev/null 2>&1; then
	adduser airplanes-feed video || true
fi

# State directory the feed daemons + claim flow write to. The overlay ships the
# read-only release tree; the mutable state dir is image-created here.
install -d -m 0755 /etc/airplanes
