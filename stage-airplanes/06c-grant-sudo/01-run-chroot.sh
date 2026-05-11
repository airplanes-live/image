#!/bin/bash
# pi-gen invokes via `bash 01-run-chroot.sh` so shebang flags are ignored;
# explicit set -e is needed.
set -e

export PATH="/usr/local/sbin:${PATH}"

# Enable the unit so systemd starts it at multi-user.target on every boot.
# The unit self-gates via ConditionPathExists=!/var/lib/airplanes/grant-sudo-done,
# so once a successful run lands the marker, subsequent boots short-circuit
# before invoking the script.
systemctl enable airplanes-grant-sudo.service
