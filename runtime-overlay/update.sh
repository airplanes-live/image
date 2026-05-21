#!/usr/bin/env bash
# update.sh — thin on-device update entrypoint for the runtime overlay.
#
# Called by the sudoers-pinned self-update helper at
# /usr/local/lib/airplanes-runtime/runtime-self-update.sh (lands in a
# follow-up change). The helper is the canonical entry point and owns the
# upgrade flock at /run/airplanes/runtime-update.lock for the entire upgrade
# protocol (state read/write, backups, installer, restart, health gates,
# rollback). update.sh runs WITHIN that lock and therefore does not take
# its own.
#
# Direct invocation (operator triage from a root shell) bypasses the
# helper's lock and is the operator's responsibility — concurrent direct
# runs are not serialised.
#
# Pin the lib dir at startup so a `current` symlink flip mid-process
# doesn't desync helper paths (resolved decision 16).

set -euo pipefail

_self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

bash "$_self_dir/install.sh" --runtime
