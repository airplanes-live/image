#!/usr/bin/env bash
# Image-side post-reboot probes, sourced by feed/test/image-boot.sh's run.sh
# during the 'updated' phase. Inherits set -euo pipefail and the fail /
# assert_* / assert_service_healthy helpers from run.sh.
#
# Covers the gaps not addressed by feed's contract assertions:
#   - airplanes-first-run consumed the synthetic boot config (rename to
#     .applied.txt, hostname change, feed.env merge with synthesized
#     MLATSERVER + TARGET).
#   - lighttpd + webconfig + sshd reach active.
#   - webconfig HTTP responds over loopback via the lighttpd reverse proxy.

echo "image-probe: starting image-side assertions"

# Boot-config apply state.
assert_file /boot/firmware/airplanes-config.applied.txt
assert_not_exists /boot/firmware/airplanes-config.txt
assert_not_exists /boot/firmware/airplanes-config.error.txt
assert_contains /etc/hostname 'boot-smoke-host'
assert_contains /etc/airplanes/feed.env 'MLATSERVER='
assert_contains /etc/airplanes/feed.env 'boot-smoke-feed.local'

# Services reach active.
assert_service_healthy lighttpd.service
assert_service_healthy airplanes-webconfig.service
assert_service_healthy ssh.service

# Webconfig HTTP via lighttpd reverse proxy. 401 is the legitimate response
# before initial setup completes; anything in the 200/300/401 band proves the
# request reached webconfig through lighttpd. 5xx, connection refused, or a
# missing binary all fail here.
http_code="$(curl --silent --show-error --output /dev/null \
    --write-out '%{http_code}' --max-time 10 http://127.0.0.1/ || echo 000)"
case "$http_code" in
    200|301|302|303|401) ;;
    *) fail "webconfig HTTP probe returned unexpected code: $http_code" ;;
esac

# Claim timer is scheduled (not necessarily currently running).
systemctl list-timers --all --no-pager 2>/dev/null | grep -q airplanes-claim \
    || fail "airplanes-claim.timer not registered"

echo "image-probe: passed"
