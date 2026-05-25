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
#   readsb  — readsb.service, airplanes-978.service (User=readsb)
#   tar1090 — upstream-staged tar1090.service (User=tar1090)
# graphs1090 and dump978-fa run as root. No unit declares Group=, so no
# dedicated group is created (tar1090 lands in `nogroup`, matching upstream
# tar1090 install.sh).
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
