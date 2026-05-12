#!/usr/bin/env bash
# Host-side pre-boot setup for the image boot-smoke job.
#
# Invoked by feed/test/image-boot.sh via AIRPLANES_BOOT_SMOKE_EXTRA_SETUP
# while $ROOT_MNT and $BOOT_MNT are rw-mounted on the host. Drops:
#
#   - /opt/airplanes-boot-smoke/extra-probe.sh in the rootfs, sourced by
#     feed's run.sh during the post-reboot 'updated' phase.
#   - /boot/firmware/airplanes-config.txt with bootstrap keys, exercising
#     airplanes-first-run.service end-to-end during the initial boot.
#
# Env: ROOT_MNT, BOOT_MNT, IMAGE_CONTRACT (set by caller).

set -euo pipefail

: "${ROOT_MNT:?ROOT_MNT not set}"
: "${BOOT_MNT:?BOOT_MNT not set}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

install -d -m 0755 "$ROOT_MNT/opt/airplanes-boot-smoke"
install -m 0755 "$script_dir/extra-probe.sh" \
    "$ROOT_MNT/opt/airplanes-boot-smoke/extra-probe.sh"

# Bootstrap-only keys — exercises parse_boot_config's 5-key allowlist
# (HOSTNAME, FEED_HOST) end-to-end on first boot. WIFI_* deliberately omitted:
# the smoke runs offline under QEMU, and a stray NM keyfile would just live
# unused on the rootfs without proving anything that test_first_run_wifi.bats
# doesn't already cover.
cat > "$BOOT_MNT/airplanes-config.txt" <<'EOF'
HOSTNAME=boot-smoke-host
FEED_HOST=boot-smoke-feed.local
EOF
