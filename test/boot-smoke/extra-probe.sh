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

# ---------------------------------------------------------------------------
# Webconfig upgrade test functions — see usage below the SSE probe.
# ---------------------------------------------------------------------------

# Channel-aware expected version after a successful Phase A upgrade.
_wcu_good_version() {
    case "$1" in
        stable) printf '%s' v9.9.99 ;;
        dev)    printf '%s' dev-latest ;;
        *)      fail "_wcu_good_version: unknown channel '$1'" ;;
    esac
}

# Channel-aware expected version after Phase B's broken-release upload (the
# version the manifest carries before rollback). For dev mode this matches
# the good version since dev-latest is the same string in both directions.
_wcu_broken_version() {
    case "$1" in
        stable) printf '%s' v9.9.100 ;;
        dev)    printf '%s' dev-latest ;;
        *)      fail "_wcu_broken_version: unknown channel '$1'" ;;
    esac
}

_wcu_manifest_version() {
    jq -r .version /etc/airplanes/webconfig-release.json 2>/dev/null
}

_wcu_poll_manifest_version() {
    local want="$1" deadline=$(( SECONDS + ${2:-60} ))
    local got
    while [ "$SECONDS" -lt "$deadline" ]; do
        got="$(_wcu_manifest_version)"
        [[ "$got" == "$want" ]] && return 0
        sleep 2
    done
    got="$(_wcu_manifest_version)"
    echo "  manifest=$got want=$want" >&2
    return 1
}

# Posts /api/webconfig-update with the same Origin + Content-Type + cookie
# jar the SSE probe captured. Returns the HTTP code in stdout.
_wcu_post_update() {
    local cookiejar="$1"
    curl --silent --show-error --output /dev/null \
        --write-out '%{http_code}' --max-time 30 \
        -X POST \
        -H 'Content-Type: application/json' \
        -H 'Origin: http://127.0.0.1' \
        -b "$cookiejar" \
        --data '{}' \
        http://127.0.0.1/api/webconfig-update
}

_wcu_health_200() {
    local code
    code="$(curl --silent --show-error --output /dev/null \
        --write-out '%{http_code}' --max-time 5 http://127.0.0.1/health || echo 000)"
    [[ "$code" == "200" ]]
}

# Re-authenticate against /api/auth/login and refresh the cookie jar in
# place. Used between phases because Phase A's actual upgrade restarts the
# webconfig service, which invalidates the in-memory session token captured
# in the SSE probe's /api/setup call. Hard-codes the same probe password
# the SSE setup uses (see sse_body below) — these must stay in sync.
# Echoes the HTTP code to stderr on failure so a 409/429/locked-out path
# distinguishes itself from a genuine 401 in the CI log.
_wcu_relogin() {
    local cookiejar="$1"
    local code
    code="$(curl --silent --show-error --output /dev/null \
        --write-out '%{http_code}' --max-time 10 \
        -X POST \
        -H 'Content-Type: application/json' \
        -H 'Origin: http://127.0.0.1' \
        --data '{"password":"ProbePw1234XX"}' \
        -c "$cookiejar" \
        http://127.0.0.1/api/auth/login)"
    if [[ "$code" != "200" ]]; then
        echo "  /api/auth/login returned $code" >&2
        return 1
    fi
}

# _wcu_wait_for_unit_inactive UNIT PHASE_LABEL [DEADLINE_SECS]
#
# Waits up to DEADLINE_SECS (default 180) for the transient
# airplanes-webconfig-update.service unit to exit. systemctl is-active
# returns 0 while running, non-zero (inactive / failed / not-found-after-
# collect) when done. The unit has --collect, so a clean exit garbage-
# collects it entirely.
_wcu_wait_for_unit_inactive() {
    local unit="$1" label="$2" deadline_secs="${3:-180}"
    local deadline=$(( SECONDS + deadline_secs ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        fail "image-probe: $label: $unit still active after ${deadline_secs}s"
    fi
}

_wcu_run_phase_a_and_b() {
    local channel="$1" cookiejar="$2"
    local good_version
    good_version="$(_wcu_good_version "$channel")"
    # _wcu_broken_version is informational — we don't compare against it
    # directly post-rollback because rollback restores the pre-attempt
    # manifest. For dev channel it would also be 'dev-latest' anyway.
    local unit=airplanes-webconfig-update.service

    # Phase A — happy upgrade to the good release. Capture the unix time
    # BEFORE the POST so the journal-since filter below excludes anything
    # the helper logged on prior unrelated runs.
    echo "image-probe:   Phase A: POST /api/webconfig-update (→ $good_version)"
    local phase_a_start
    phase_a_start=$(date +%s)
    local code
    code="$(_wcu_post_update "$cookiejar")"
    [[ "$code" == "202" || "$code" == "200" ]] \
        || fail "image-probe: Phase A: /api/webconfig-update returned $code (want 200/202)"

    # Wait for the transient unit to finish before checking on-disk state —
    # on the dev channel good_version equals broken_version equals
    # 'dev-latest', so the manifest poll alone would succeed trivially even
    # if the helper short-circuited. The Phase B wait below has the same
    # rationale.
    _wcu_wait_for_unit_inactive "$unit" "Phase A"
    sleep 2  # let the journal flush

    _wcu_poll_manifest_version "$good_version" 60 \
        || fail "image-probe: Phase A: manifest never reached $good_version"

    [[ ! -f /usr/local/bin/airplanes-webconfig.prev ]] \
        || fail "image-probe: Phase A: binary .prev not cleaned"
    [[ ! -f /etc/systemd/system/airplanes-webconfig.service.prev ]] \
        || fail "image-probe: Phase A: unit .prev not cleaned"
    [[ ! -f /etc/airplanes/webconfig-release.json.prev ]] \
        || fail "image-probe: Phase A: manifest .prev not cleaned"

    assert_service_healthy airplanes-webconfig.service
    _wcu_health_200 || fail "image-probe: Phase A: /health did not return 200 after upgrade"
    /usr/local/bin/airplanes-webconfig --validate-sudoers \
        || fail "image-probe: Phase A: validate-sudoers failed (cross-version parity broken)"

    # Positive journal signal that the helper actually completed the upgrade.
    # Without this, a future bug that short-circuits the helper (POST returns
    # 202 but the helper exits before binary swap — e.g. a wrapper-level
    # flock collision returning EX_TEMPFAIL) would still pass every assertion
    # above on the dev channel where good_version is unchanged byte-for-byte.
    if ! journalctl -u "$unit" --no-pager --since "@$phase_a_start" 2>&1 \
            | grep -q 'health OK after restart'; then
        fail "image-probe: Phase A: journal missing '/health OK after restart' (helper did not complete the upgrade)"
    fi

    # Phase A actually restarted airplanes-webconfig.service via the helper's
    # `systemctl restart` (post-flock-fix this is no longer a no-op), which
    # cleared the in-memory session map. The cookie jar we inherited from
    # the SSE probe's /api/setup call now points at a session the new
    # process has never heard of — re-login or Phase B's POST returns 401.
    _wcu_relogin "$cookiejar" \
        || fail "image-probe: Phase B: re-login via /api/auth/login failed after Phase A service restart"

    # Phase B — broken release, expect rollback.
    echo "image-probe:   Phase B: pushing broken-release tag, POST /api/webconfig-update"
    sudo -n /usr/local/lib/airplanes-boot-smoke/push-broken-tag.sh "$channel" \
        || fail "image-probe: Phase B: push-broken-tag.sh failed"

    # Phase A succeeded so manifest is already $good_version going into
    # Phase B. The polling check below only verifies post-Phase-B state, so
    # we MUST wait for the transient unit to actually finish before reading
    # the manifest — otherwise the poll reads the pre-Phase-B value and the
    # assertion succeeds trivially.
    local phase_b_start
    phase_b_start=$(date +%s)

    code="$(_wcu_post_update "$cookiejar")"
    [[ "$code" == "202" || "$code" == "200" ]] \
        || fail "image-probe: Phase B: /api/webconfig-update returned $code (want 200/202)"

    # Default helper timing: ~10s health probe + restart + journal flush;
    # budget 120s plus slack via the helper's default 180s.
    _wcu_wait_for_unit_inactive "$unit" "Phase B"
    sleep 2  # let the journal flush

    # Convergence: rollback restored the manifest to the pre-attempt good
    # version. (For dev channel both versions are 'dev-latest' so the
    # version-equality check above is satisfied trivially; the binary
    # rollback is the real signal there. Cover it below.)
    local manifest_after
    manifest_after="$(_wcu_manifest_version)"
    [[ "$manifest_after" == "$good_version" ]] \
        || fail "image-probe: Phase B: manifest=$manifest_after expected rollback to $good_version"

    assert_service_healthy airplanes-webconfig.service
    _wcu_health_200 || fail "image-probe: Phase B: /health did not return 200 after rollback"

    # Journal evidence that the rollback code path actually ran. Restrict to
    # entries since the POST so a successful Phase A's journal noise can't
    # match. Without this the happy-path-only case (binary somehow served
    # /health) could pass.
    if ! journalctl -u "$unit" --no-pager --since "@$phase_b_start" 2>&1 \
            | grep -qE 'health probe exhausted|rolling back'; then
        fail "image-probe: Phase B: journal missing 'health probe exhausted' / 'rolling back'"
    fi
}

_wcu_verify_persistence() {
    local channel="$1"
    local expected
    expected="$(_wcu_good_version "$channel")"

    local got
    got="$(_wcu_manifest_version)"
    [[ "$got" == "$expected" ]] \
        || fail "image-probe: persistence: manifest=$got expected=$expected"

    assert_service_healthy airplanes-webconfig.service
    _wcu_health_200 \
        || fail "image-probe: persistence: /health did not return 200 after reboot"

    /usr/local/bin/airplanes-webconfig --validate-sudoers \
        || fail "image-probe: persistence: validate-sudoers failed after reboot"

    [[ ! -f /usr/local/bin/airplanes-webconfig.prev ]] \
        || fail "image-probe: persistence: binary .prev leaked across reboot"
    [[ ! -f /etc/systemd/system/airplanes-webconfig.service.prev ]] \
        || fail "image-probe: persistence: unit .prev leaked across reboot"
    [[ ! -f /etc/airplanes/webconfig-release.json.prev ]] \
        || fail "image-probe: persistence: manifest .prev leaked across reboot"
}

# ---------------------------------------------------------------------------

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

# Tmpfs sizing oneshot ran (oneshot → inactive(dead) on success; not
# "failed"). Then verify the actual on-disk effects.
_runresize_state="$(systemctl show airplanes-run-resize.service \
    --property=ActiveState --value 2>/dev/null || true)"
[[ "$_runresize_state" == "active" || "$_runresize_state" == "inactive" ]] \
    || fail "airplanes-run-resize.service in unexpected state: $_runresize_state"
_runresize_result="$(systemctl show airplanes-run-resize.service \
    --property=Result --value 2>/dev/null || true)"
[[ "$_runresize_result" == "success" ]] \
    || fail "airplanes-run-resize.service result != success (was $_runresize_result)"

# /run is at least 128 MiB. Exact size depends on RAM (max of 128 MiB
# and 20% MemTotal); the QEMU host's RAM may or may not exceed the
# floor — only the lower bound is universal.
_run_bytes="$(findmnt -no SIZE -b --target /run 2>/dev/null || echo 0)"
(( _run_bytes >= 128 * 1024 * 1024 )) \
    || fail "/run tmpfs is $_run_bytes bytes (< 128 MiB floor)"

# /run/collectd is its own tmpfs mount of exactly 64 MiB. Use -M to
# require a mountpoint match (not just "is the parent tmpfs?").
findmnt -M /run/collectd >/dev/null 2>&1 \
    || fail "/run/collectd is not a separate mountpoint (would let RRDs starve /run/systemd)"
_collectd_fstype="$(findmnt -no FSTYPE -M /run/collectd 2>/dev/null || true)"
[[ "$_collectd_fstype" == "tmpfs" ]] \
    || fail "/run/collectd fstype is '$_collectd_fstype' (expected tmpfs)"
_collectd_bytes="$(findmnt -no SIZE -b -M /run/collectd 2>/dev/null || echo 0)"
(( _collectd_bytes == 64 * 1024 * 1024 )) \
    || fail "/run/collectd tmpfs is $_collectd_bytes bytes (expected exactly 64 MiB)"
# run-collectd.mount itself reached active without errors.
_collectd_mount_state="$(systemctl show run-collectd.mount \
    --property=ActiveState --value 2>/dev/null || true)"
[[ "$_collectd_mount_state" == "active" ]] \
    || fail "run-collectd.mount ActiveState=$_collectd_mount_state (expected active)"
_collectd_mount_result="$(systemctl show run-collectd.mount \
    --property=Result --value 2>/dev/null || true)"
[[ "$_collectd_mount_result" == "success" ]] \
    || fail "run-collectd.mount Result=$_collectd_mount_result (expected success)"

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

# Re-entrant: the webconfig-upgrade-qemu variant reboots from inside this
# probe and re-sources us afterwards; by then /api/setup has already moved
# the device to "initialized" and the SSE password-setup+stream path is no
# longer applicable. Skip it cleanly — the persistence path below probes
# /health and the running service, which is what matters for a second pass.
if grep -q '"state":"uninitialized"' "$sse_state_out"; then
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
else
    echo "image-probe: SSE probe skipped (state=$(cat "$sse_state_out")) — already initialized, second pass"
fi
rm -f "$sse_state_out" "$sse_stream_out"

# Webconfig-upgrade variant — gated on the marker file the boot-smoke pre-boot
# setup writes when AIRPLANES_BOOT_SMOKE_TEST_WEBCONFIG_UPGRADE=1. The marker
# contains the resolver channel (`stable` or `dev`), matching what stage 06
# baked into /etc/airplanes/release-channel. Reuses the SSE probe's
# authenticated cookie jar.
if [[ -s /var/lib/airplanes-boot-smoke/webconfig-upgrade-channel ]]; then
    _wcu_channel="$(cat /var/lib/airplanes-boot-smoke/webconfig-upgrade-channel)"
    _wcu_phase_file=/var/lib/airplanes-boot-smoke/webconfig-upgrade-phase
    _wcu_phase="$(cat "$_wcu_phase_file" 2>/dev/null || true)"

    case "$_wcu_phase" in
        '')
            echo "image-probe: webconfig-upgrade phase A+B (channel=$_wcu_channel)"
            _wcu_run_phase_a_and_b "$_wcu_channel" "$sse_cookiejar"
            printf '%s' phases-done > "$_wcu_phase_file"
            sync
            echo "image-probe: webconfig-upgrade rebooting to verify reboot persistence"
            systemctl reboot
            # systemctl reboot returns immediately; sleep so the journal flushes
            # before the kernel cuts power. The harness's case statement on the
            # next boot will re-enter the `updated` phase and re-source us.
            sleep 60
            fail "image-probe: webconfig-upgrade: systemctl reboot did not take effect within 60s"
            ;;
        phases-done)
            echo "image-probe: webconfig-upgrade reboot persistence (channel=$_wcu_channel)"
            _wcu_verify_persistence "$_wcu_channel"
            rm -f "$_wcu_phase_file"
            ;;
        *)
            fail "image-probe: webconfig-upgrade: unexpected phase '$_wcu_phase'"
            ;;
    esac
fi

rm -f "$sse_cookiejar"

echo "image-probe: passed"
