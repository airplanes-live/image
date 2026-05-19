#!/bin/bash
# Explicit `set -e` — pi-gen invokes via `on_chroot < 01-run-chroot.sh`,
# which feeds the body to bash and ignores the shebang's flags.
set -e

export PATH="/usr/local/sbin:${PATH}"

systemctl enable airplanes-run-resize.service
systemctl enable run-collectd.mount
