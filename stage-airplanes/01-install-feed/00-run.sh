#!/bin/bash -e

: "${AIRPLANES_FEED_REPO:?AIRPLANES_FEED_REPO must be set by config-stable/dev}"
: "${AIRPLANES_FEED_BRANCH:?AIRPLANES_FEED_BRANCH must be set by config-stable/dev}"
: "${AIRPLANES_READSB_REPO:?AIRPLANES_READSB_REPO must be set by config-stable/dev}"
: "${AIRPLANES_READSB_BRANCH:?AIRPLANES_READSB_BRANCH must be set by config-stable/dev}"

FEED_BUILD_DIR="${ROOTFS_DIR}/usr/local/src/airplanes-feed-build"

# init+fetch+checkout works for branches and SHAs uniformly. `-B` creates a
# local branch ref named `${AIRPLANES_FEED_BRANCH}` so feed/install.sh's
# in-chroot `git clone --branch ${AIRPLANES_FEED_BRANCH} file://...` re-clone
# resolves. (For SHA-pinned stable, the local branch name happens to be the
# 40-char SHA, which git accepts as a valid branch name.)
rm -rf "${FEED_BUILD_DIR}"
install -d -m 755 "${FEED_BUILD_DIR}"
git -C "${FEED_BUILD_DIR}" init -q
git -C "${FEED_BUILD_DIR}" remote add origin "${AIRPLANES_FEED_REPO}"
git -C "${FEED_BUILD_DIR}" fetch --depth 1 origin "${AIRPLANES_FEED_BRANCH}"
git -C "${FEED_BUILD_DIR}" checkout -q -B "${AIRPLANES_FEED_BRANCH}" FETCH_HEAD

# Record the resolved feed SHA for the build manifest.
git -C "${FEED_BUILD_DIR}" rev-parse HEAD > "${ROOTFS_DIR}/etc/airplanes/.build-feed-sha"

# Pre-resolve airplanes-live/readsb (outbound feed binary) SHA for the build
# manifest. feed/install.sh clones this inside the chroot; we capture the SHA
# the dev branch points at *now* so the manifest reflects build-time intent.
# For stable, AIRPLANES_READSB_BRANCH is already a 40-char SHA — ls-remote
# round-trips it; if remote lookup fails (no internet, repo offline), fall
# back to the env var only if it is itself a 40-hex SHA, so a branch typo
# can't silently produce `"airplanes_readsb": "dev"`.
remote_out="$(git ls-remote "${AIRPLANES_READSB_REPO}" "${AIRPLANES_READSB_BRANCH}" 2>/dev/null || true)"
readsb_sha="${remote_out%%[[:space:]]*}"
if [[ ! "$readsb_sha" =~ ^[0-9a-f]{40}$ ]]; then
	if [[ "$AIRPLANES_READSB_BRANCH" =~ ^[0-9a-f]{40}$ ]]; then
		readsb_sha="$AIRPLANES_READSB_BRANCH"
	else
		echo "ERROR: cannot resolve airplanes-readsb SHA: ls-remote returned no ref for '${AIRPLANES_READSB_BRANCH}' on ${AIRPLANES_READSB_REPO} AND the branch ref is not a 40-hex SHA" >&2
		exit 1
	fi
fi
printf '%s\n' "$readsb_sha" > "${ROOTFS_DIR}/etc/airplanes/.build-airplanes-readsb-sha"
