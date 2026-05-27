#!/usr/bin/env bash
# Rollback for 0001-create-service-accounts.sh: intentionally a no-op.
#
# Deleting a service account on rollback could break a concurrent prior
# release that still relies on it, and /etc/passwd /etc/group /etc/shadow are
# NOT part of mutable_paths preimage restoration — so a created account is
# deliberately left in place. This mirrors the conservative no-op rollback of
# the group_membership migration (install-common.sh). Idempotent success.
set -euo pipefail
exit 0
