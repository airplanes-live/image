#!/bin/bash
# start-orchestrator.sh — stable image-owned launch path for
# airplanes-update-orchestrator. Webconfig's sudoers entry pins this path,
# so it MUST exist on every image regardless of which runtime-overlay tag
# is flipped in at /opt/airplanes-runtime/current.
#
# The orchestrator binary itself lives inside the runtime overlay (which
# moves with each runtime release). This trampoline exec()s the binary
# after verifying it is a regular file and executable; if the overlay has
# not yet been laid down (build-time race, missing release), exit 75
# (EX_TEMPFAIL) so the capability gate in webconfig translates it to
# HTTP 503 rather than a 500.

set -Eeuo pipefail

target=/opt/airplanes-runtime/current/lib/airplanes-update-orchestrator

if [[ ! -f "$target" ]]; then
    echo "start-orchestrator: target missing or not a regular file: $target" >&2
    exit 75
fi
if [[ ! -x "$target" ]]; then
    echo "start-orchestrator: target is not executable: $target" >&2
    exit 75
fi

exec "$target" "$@"
