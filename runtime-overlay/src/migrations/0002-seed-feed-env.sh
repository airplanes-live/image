#!/usr/bin/env bash
# Forward migration: seed /etc/airplanes/feed.env from the overlay-shipped
# default template when it does not already exist.
#
# Fresh flash seeds feed.env in the chroot stage
# (stage-airplanes/02-install-runtime-overlay/01-run-chroot.sh). Build-mode
# skips migrations, so this never double-runs at flash — it exists for the
# UPDATE path: a feeder updating into an overlay that delivers the feed stack
# (which previously shipped feed.env via stage 01's feed/install.sh) must end
# up with a feed.env so the feed daemons have something to source.
#
# NEVER overwrites an existing feed.env — that is operator/first-run state
# (declared a mutable_path so the updater backs it up before any mutation).
# Create-if-missing only. The default template is the canonical feed contract,
# produced by feed's own configure.sh --build-mode at overlay-build time.
set -euo pipefail

RELEASE_DIR="${RELEASE_DIR:?RELEASE_DIR not set}"
TARGET_ROOT="${AIRPLANES_RUNTIME_TARGET_ROOT:-}"

default_template="$RELEASE_DIR/share/airplanes/feed.env.default"
feed_env="${TARGET_ROOT}/etc/airplanes/feed.env"

# No template in this release (e.g. a decoder-only overlay) → nothing to seed.
[[ -f "$default_template" ]] || exit 0

if [[ ! -e "$feed_env" ]]; then
	install -d -m 0755 "$(dirname "$feed_env")"
	install -m 0644 "$default_template" "$feed_env"
fi
