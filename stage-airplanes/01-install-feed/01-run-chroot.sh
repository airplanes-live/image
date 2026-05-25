#!/bin/bash -e

export PATH="/usr/local/sbin:${PATH}"

# Build mode skips service starts, claim registration, runtime checks, and the
# interactive configure flow (feed/configure.sh:157). configure_noninteractive
# still requires placeholders for location / MLAT user; these are the default
# values baked into feed.env at image freeze. Operational values are set by
# the user via the webconfig UI after first boot; first-run on the device only
# handles the 6-key bootstrap allowlist (HOSTNAME, WIFI_*, FEED_HOST, WEBSITE_URL).
#
# MLAT is off by default on a fresh image: the operator must explicitly
# enable it via the webconfig after entering real coordinates. A flashed
# feeder still feeds Beast (ADS-B) — only MLAT waits for opt-in.
# GEO_CONFIGURED follows from the lat=0/lon=0 placeholders via
# configure.sh's derive_geo_configured. ALTITUDE=0m is a valid sea-level
# value the operator can keep or replace.
export AIRPLANES_BUILD_MODE=1
export AIRPLANES_FEED_REPO="file:///usr/local/src/airplanes-feed-build"
export AIRPLANES_FEED_BRANCH="${AIRPLANES_FEED_BRANCH}"
export AIRPLANES_READSB_REPO="${AIRPLANES_READSB_REPO}"
export AIRPLANES_READSB_BRANCH="${AIRPLANES_READSB_BRANCH}"
export AIRPLANES_MLAT_USER=airplanes-live-image
export AIRPLANES_MLAT_ENABLED=false
export AIRPLANES_LATITUDE=0
export AIRPLANES_LONGITUDE=0
export AIRPLANES_ALTITUDE=0m

cd /usr/local/src/airplanes-feed-build
bash install.sh --build-mode
