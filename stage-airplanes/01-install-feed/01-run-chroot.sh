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

# Create the airplanes-feed system group + user. Fallback chain mirrors feed's
# ensure_airplanes_feed_account so the chroot works on minimal containers (e.g.
# debian:trixie-slim used by feed-overlay-smoke) that may lack the `adduser`
# package.
if ! getent group airplanes-feed >/dev/null 2>&1; then
	addgroup --system airplanes-feed 2>/dev/null \
		|| groupadd --system airplanes-feed 2>/dev/null \
		|| { echo "ERROR: failed to create airplanes-feed group" >&2; exit 1; }
fi
if ! id -u airplanes-feed >/dev/null 2>&1; then
	adduser --system --ingroup airplanes-feed \
		--home /opt/airplanes/current/share/airplanes --no-create-home --quiet airplanes-feed 2>/dev/null \
		|| useradd --system --gid airplanes-feed \
		--home-dir /opt/airplanes/current/share/airplanes --no-create-home airplanes-feed 2>/dev/null \
		|| { echo "ERROR: failed to create airplanes-feed user" >&2; exit 1; }
fi

# Pi hardware: the daemon user needs the `video` group so vcgencmd can read
# /dev/vchiq for the diagnostics throttle fields. Add it when the group exists.
if getent group video >/dev/null 2>&1; then
	adduser airplanes-feed video 2>/dev/null \
		|| usermod -aG video airplanes-feed 2>/dev/null \
		|| true
fi

# State directory the feed daemons + claim flow write to. The overlay ships the
# read-only release tree; the mutable state dir is image-created here.
install -d -m 0755 /etc/airplanes
