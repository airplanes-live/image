#!/bin/bash -e

export PATH="/usr/local/sbin:${PATH}"

# Build mode skips service starts, claim registration, runtime checks, and the
# interactive configure flow (feed/configure.sh:157). configure_noninteractive
# still requires sentinel placeholders; first-run merges real values from
# /boot/firmware/airplanes-config.txt.
export AIRPLANES_BUILD_MODE=1
export AIRPLANES_FEED_REPO="file:///usr/local/src/airplanes-feed-build"
export AIRPLANES_FEED_BRANCH="${AIRPLANES_FEED_BRANCH}"
export AIRPLANES_READSB_REPO="${AIRPLANES_READSB_REPO}"
export AIRPLANES_READSB_BRANCH="${AIRPLANES_READSB_BRANCH}"
export AIRPLANES_MLAT_USER=airplanes-live-image
export AIRPLANES_LATITUDE=0
export AIRPLANES_LONGITUDE=0
export AIRPLANES_ALTITUDE=0m

cd /usr/local/src/airplanes-feed-build
bash install.sh --build-mode
