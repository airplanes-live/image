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

# End-to-end SSE probe: real lighttpd -> real webconfig -> real journald.
# Catches three regressions in one shot:
#   * Go-side http.Server.WriteTimeout cutting the SSE stream off (the
#     deadline-setting unit test in webconfig/internal/logs/logs_test.go
#     is the layered companion to this probe).
#   * lighttpd `server.stream-response-body = 2` missing from
#     stage-airplanes/05-install-webconfig/files/etc/lighttpd/conf-available/
#     40-airplanes-webconfig.conf — mod_proxy would buffer the SSE body and
#     no `data:` line would arrive within the 5s curl window.
#   * journalctl path or /api/log/{unit} auth/route wiring breaking.
echo "image-probe: SSE stream end-to-end"

sse_body='{"password":"ProbePw1234XX"}'
sse_cookiejar="$(mktemp)"
sse_state_out="$(mktemp)"
sse_stream_out="$(mktemp)"

curl --silent --show-error --max-time 5 \
    http://127.0.0.1/api/state > "$sse_state_out" || true
grep -q '"state":"uninitialized"' "$sse_state_out" \
    || fail "SSE probe: expected /api/state == uninitialized; got: $(cat "$sse_state_out")"

# /api/setup auto-logs-in on success — capture the session cookie for the
# follow-up SSE GET. Origin == Host satisfies the POST-mutation origin guard.
sse_setup_code="$(curl --silent --show-error --output /dev/null \
    --write-out '%{http_code}' --max-time 10 \
    -X POST -H 'Content-Type: application/json' -H 'Origin: http://127.0.0.1' \
    --data "$sse_body" -c "$sse_cookiejar" \
    http://127.0.0.1/api/setup)"
[[ "$sse_setup_code" == "200" ]] \
    || fail "SSE probe: /api/setup returned $sse_setup_code (want 200)"

# Open the SSE stream for 5s. `--max-time 5` ends curl with exit 28; we
# accept that and inspect the captured bytes. webconfig.service is the
# unit we stream — guaranteed to have journal entries since it's running.
curl --silent --show-error --no-buffer --max-time 5 \
    -b "$sse_cookiejar" \
    http://127.0.0.1/api/log/webconfig > "$sse_stream_out" || true

[[ -s "$sse_stream_out" ]] \
    || fail "SSE probe: stream emitted no data within 5s — proxy buffering or upstream WriteTimeout regression?"
grep -q '^data: ' "$sse_stream_out" \
    || fail "SSE probe: output missing 'data: ' prefix; head: $(head -c 500 "$sse_stream_out")"

echo "image-probe: SSE stream end-to-end passed ($(wc -l < "$sse_stream_out") lines)"
rm -f "$sse_cookiejar" "$sse_state_out" "$sse_stream_out"

echo "image-probe: passed"
