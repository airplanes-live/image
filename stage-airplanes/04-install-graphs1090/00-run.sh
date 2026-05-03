#!/bin/bash -e

: "${AIRPLANES_GRAPHS1090_REPO:?must be set by config-stable/dev}"
: "${AIRPLANES_GRAPHS1090_BRANCH:?must be set by config-stable/dev}"

GRAPHS1090_DIR="${ROOTFS_DIR}/usr/share/graphs1090/git"

rm -rf "$GRAPHS1090_DIR"
install -d -m 755 "$GRAPHS1090_DIR"
git -C "$GRAPHS1090_DIR" init -q
git -C "$GRAPHS1090_DIR" remote add origin "$AIRPLANES_GRAPHS1090_REPO"
git -C "$GRAPHS1090_DIR" fetch --depth 1 origin "$AIRPLANES_GRAPHS1090_BRANCH"
git -C "$GRAPHS1090_DIR" checkout -q FETCH_HEAD

git -C "$GRAPHS1090_DIR" rev-parse HEAD > "${ROOTFS_DIR}/etc/airplanes/.build-graphs1090-sha"
