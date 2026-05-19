#!/bin/bash -e

: "${AIRPLANES_TAR1090_REPO:?must be set by config-stable/dev}"
: "${AIRPLANES_TAR1090_BRANCH:?must be set by config-stable/dev}"
: "${AIRPLANES_TAR1090_DB_REPO:?must be set by config-stable/dev}"
: "${AIRPLANES_TAR1090_DB_BRANCH:?must be set by config-stable/dev}"

fetch_repo() {
	local dir="$1" repo="$2" ref="$3"
	rm -rf "$dir"
	install -d -m 755 "$dir"
	git -C "$dir" init -q
	git -C "$dir" remote add origin "$repo"
	git -C "$dir" fetch --depth 1 origin "$ref"
	git -C "$dir" checkout -q FETCH_HEAD
}

TAR1090_DIR="${ROOTFS_DIR}/usr/local/src/airplanes-tar1090-build"
TAR1090_DB_DIR="${ROOTFS_DIR}/usr/local/share/tar1090/git-db"

fetch_repo "$TAR1090_DIR" "$AIRPLANES_TAR1090_REPO" "$AIRPLANES_TAR1090_BRANCH"
git -C "$TAR1090_DIR" rev-parse HEAD > "${ROOTFS_DIR}/etc/airplanes/.build-tar1090-sha"

fetch_repo "$TAR1090_DB_DIR" "$AIRPLANES_TAR1090_DB_REPO" "$AIRPLANES_TAR1090_DB_BRANCH"
git -C "$TAR1090_DB_DIR" rev-parse HEAD > "${ROOTFS_DIR}/etc/airplanes/.build-tar1090-db-sha"

# tar1090's install.sh curl-checks tar1090-db's remote master/version and runs
# `getGIT db_repo master git-db` if it differs. With origin still pointing at
# GitHub, that re-fetch would clobber our pinned SHA. Repoint origin at a
# guaranteed-to-fail URL: getGIT's `git fetch origin master` fails, and the
# script's `|| true` keeps our pinned tree in place.
git -C "$TAR1090_DB_DIR" remote set-url origin file:///dev/null/airplanes-pinned

# Lighttpd alias for /skyaware978/ → /run/airplanes-978/ so tar1090's UAT view
# (default URL_978="http://127.0.0.1/skyaware978") resolves to our UAT JSON.
install -D -m 0644 "${BASE_DIR:-.}/runtime-overlay/src/etc/lighttpd/conf-available/89-airplanes-978.conf" \
	"${ROOTFS_DIR}/etc/lighttpd/conf-available/89-airplanes-978.conf"

# Runtime reconciler that flips ENABLE_978 in /etc/default/tar1090 to track
# the airplanes-978 + dump978-fa runtime state. Replaces the bake-time
# ENABLE_978=yes that used to live in 01-run-chroot.sh and was wrong for
# feeders without a 978 SDR (tar1090 would spam "978.json: No such file
# or directory" every iteration).
install -D -m 0755 "${BASE_DIR:-.}/runtime-overlay/src/share/airplanes/tar1090-uat-sync.sh" \
	"${ROOTFS_DIR}/usr/local/share/airplanes/tar1090-uat-sync.sh"
install -D -m 0644 "${BASE_DIR:-.}/runtime-overlay/src/systemd/airplanes-tar1090-uat-sync.service" \
	"${ROOTFS_DIR}/etc/systemd/system/airplanes-tar1090-uat-sync.service"
install -D -m 0644 "${BASE_DIR:-.}/runtime-overlay/src/systemd/airplanes-tar1090-uat-sync.path" \
	"${ROOTFS_DIR}/etc/systemd/system/airplanes-tar1090-uat-sync.path"
