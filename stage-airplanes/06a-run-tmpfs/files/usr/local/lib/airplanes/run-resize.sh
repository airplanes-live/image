#!/bin/bash
#
# Early-boot /run tmpfs resize.
#
# systemd defaults /run to ~20% of MemTotal at pid1 init. On the
# smallest supported target (Pi Zero 2W, ~415 MiB usable) that's
# ~85 MiB — tight enough that graphs1090's RRDs + readsb + journald
# can leave /run/systemd without the 16 MiB reload buffer the
# webconfig self-update's `systemctl daemon-reload` needs.
#
# The rootfs fstab pins a 128 MiB floor (systemd-remount-fs.service
# applies it on early boot). On larger-RAM Pis the floor would shrink
# /run below systemd's own default, so this script remounts back up
# to max(128 MiB, 20%*MemTotal).
#
# Idempotent: re-running on a booted device only remounts when the
# current size is below the target. `mount -o remount,size=...` does
# not lose data even on a heavily-used /run.

set -euo pipefail

readonly RUN_FLOOR_KB=$((128 * 1024))

mem_kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo)
twenty_pct_kb=$(( mem_kb / 5 ))
if (( twenty_pct_kb > RUN_FLOOR_KB )); then
    target_run_kb="$twenty_pct_kb"
else
    target_run_kb="$RUN_FLOOR_KB"
fi
target_run_b=$(( target_run_kb * 1024 ))

current_run_b=$(findmnt -no SIZE -b --target /run 2>/dev/null || echo 0)
if (( current_run_b < target_run_b )); then
    mount -o "remount,size=${target_run_kb}k" /run
    echo "airplanes-run-resize: /run remounted to ${target_run_kb} KiB (was ${current_run_b} bytes)"
else
    echo "airplanes-run-resize: /run already at ${current_run_b} bytes (>= target ${target_run_b}); no remount"
fi
