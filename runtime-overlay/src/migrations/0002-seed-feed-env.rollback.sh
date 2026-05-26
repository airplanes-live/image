#!/usr/bin/env bash
# Rollback for 0002-seed-feed-env.sh: intentionally a no-op.
#
# feed.env is a mutable_path, so the updater snapshots it BEFORE migrations run
# and restores the preimage on rollback (a created-absent marker means the
# restore deletes the file the forward step seeded). There is nothing for this
# script to undo — the preimage mechanism owns the revert. Idempotent success.
set -euo pipefail
exit 0
