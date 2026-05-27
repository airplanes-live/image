#!/usr/bin/env bash
# Forward migration: create the service accounts the overlay's units require.
#
# Fresh flash creates these in the chroot stage
# (stage-airplanes/02-install-runtime-overlay/01-run-chroot.sh). Build-mode
# skips migrations, so this never double-runs at flash — it exists purely for
# the UPDATE path. Without it, a feeder updating into an overlay whose units
# declare User=tar1090 / User=readsb fails the unit with 217/USER before
# ExecStart runs and (Restart=always) auto-restart-loops forever.
#
# Principals (audited from the overlay's systemd units):
#   readsb        — readsb.service, airplanes-978.service (User=readsb)
#   tar1090       — upstream-staged tar1090.service (User=tar1090)
#   airplanes-feed — airplanes-feed.service, airplanes-mlat.service
#                    (User=airplanes-feed); the private airplanes-feed group
#                    also lets other accounts read the claim secret (mode 0640).
# graphs1090 and dump978-fa run as root. The readsb / tar1090 accounts declare
# no dedicated group beyond readsb's own; airplanes-feed gets a private group.
#
# adduser flags are EXACT PARITY with the chroot stage (enforced by
# test_install_account_migration.bats). Existence-only: create-if-missing,
# no-op-if-present; an existing account is trusted (accounts are only ever
# created cleanly by the chroot stage). Group membership (readsb in
# plugdev/dialout) is handled by the readsb-user-groups group_membership
# migration, which is ordered AFTER this one.
set -euo pipefail

# adduser/getent live in /usr/sbin; pin a deterministic PATH so the migration
# does not depend on the caller's (possibly minimal, systemd-spawned)
# environment. AIRPLANES_RUNTIME_MIGRATION_PATH is a test-only seam (production
# never sets it) that lets bats inject mock adduser/getent.
export PATH="${AIRPLANES_RUNTIME_MIGRATION_PATH:-/usr/sbin:/usr/bin:/sbin:/bin}"

if ! getent passwd readsb >/dev/null; then
	adduser --system --group --home /usr/local/share/readsb --no-create-home --quiet readsb
fi

if ! getent passwd tar1090 >/dev/null; then
	adduser --system --home /usr/local/share/tar1090 --no-create-home --quiet tar1090
fi

# airplanes-feed: feed + mlat daemons run as this user; a private group of the
# same name lets other accounts read the claim secret (mode 0640). Parity with
# stage-airplanes/01-install-feed/01-run-chroot.sh.
if ! getent group airplanes-feed >/dev/null; then
	addgroup --system airplanes-feed
fi
if ! getent passwd airplanes-feed >/dev/null; then
	adduser --system --ingroup airplanes-feed \
		--home /usr/local/share/airplanes --no-create-home --quiet airplanes-feed
fi
