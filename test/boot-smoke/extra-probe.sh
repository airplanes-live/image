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
# Update-orchestrator e2e probe — drives POST /api/orchestrator/start with
# every sub-helper stubbed out at its absolute path so the orchestrator's
# four-phase sequencing is exercised end-to-end without actually mutating
# apt / feed / webconfig / runtime. The bats coverage at
# test/runtime-overlay/test_orchestrator_sequence.bats exercises the
# orchestrator script in isolation; this probe exercises the click-flow
# (HTTP -> sudoers -> systemd-run -> orchestrator -> state-file) the SPA
# uses, which the bats coverage cannot reach.
#
# Stubs are installed at the four absolute paths the orchestrator
# invokes by default (no env override is possible because systemd-run's
# sudoers-pinned argv uses env_reset and the production defaults are
# hard-coded as absolute paths in the orchestrator script itself).
# All four use bind-mount (not move-aside) so cleanup is a single
# umount-in-reverse strategy and a probe abort leaves /usr/local/...
# intact via the kernel's mount table even if _orch_restore never runs:
#
#   /usr/bin/apt-get
#   /usr/local/share/airplanes/update.sh
#   /usr/local/lib/airplanes-webconfig/webconfig-self-update.sh
#   /opt/airplanes-runtime/current/lib/runtime-self-update.sh
#
# Each stub writes a marker file under
# /run/airplanes/test-orchestrator-markers/<step>.ok and sleeps briefly
# so the state file actually progresses through running -> ok rather
# than blurring straight to done. /run is tmpfs and stage 06a sizes it
# generously; the marker dir lives there alongside the state file.
# ---------------------------------------------------------------------------

# Trampoline + overlay-shipped binary that must both be present and
# executable for /api/orchestrator/start to return anything other than
# 503. Mirrors defaultOrchestratorCapable in image-webconfig. The
# capability gate is channel-asymmetric: on dev, a missing overlay
# binary is a regression (the dev runtime tag is bumped explicitly to
# carry the orchestrator); on stable, it's the expected transition
# state until a stable runtime release ships with the orchestrator.
# Channel sourced from /etc/airplanes/release-channel (written by
# stage 06; allowlist {stable, dev}). The trampoline is image-owned
# and always present on both channels — its absence is independently
# asserted earlier in this probe at line ~329 — so we only use it as
# a defensive belt-and-braces check here.
_orch_trampoline=/usr/local/lib/airplanes-webconfig/start-orchestrator.sh
_orch_binary=/opt/airplanes-runtime/current/lib/airplanes-update-orchestrator

# Absolute paths the orchestrator (runtime-overlay/src/lib/airplanes-update-orchestrator)
# invokes for each step. Kept in sync with the script's defaults block.
_orch_apt_get=/usr/bin/apt-get
_orch_feed_update=/usr/local/share/airplanes/update.sh
_orch_webconfig_update=/usr/local/lib/airplanes-webconfig/webconfig-self-update.sh
_orch_runtime_update=/opt/airplanes-runtime/current/lib/runtime-self-update.sh

_orch_state_file=/run/airplanes/orchestrator.state
# Per-run tmpfs paths assigned by _orch_run_probe via mktemp -d so a
# stale path from a previous probe attempt (e.g. a re-entry on the
# same boot) cannot satisfy our final marker assertion trivially.
_orch_marker_dir=
_orch_stub_dir=
_orch_call_log=

# Tracks which of the four bind-mounts are currently active so the
# restore loop can umount only what was actually mounted, in reverse
# order, and ignores failures. Each entry is a target path.
_orch_active_binds=()

# _orch_write_stub PATH STEP_NAME — write a marker-writing stub script
# to PATH that records "<iso-ts> STEP argv" both to a per-step .ok
# marker (presence assertion) and to the shared sequence log (count +
# order assertions). sleep 1 so the orchestrator's state file passes
# through running -> ok rather than racing straight to done.
_orch_write_stub() {
    local out="$1" step="$2"
    cat > "$out" <<EOF
#!/bin/bash
# Boot-smoke orchestrator stub for ${step}.
set -euo pipefail
mkdir -p "${_orch_marker_dir}"
ts="\$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
printf '%s %s %s\n' "\$ts" "${step}" "\$*" >> "${_orch_marker_dir}/${step}.ok"
# Atomic append to the shared sequence log so concurrent invocations
# (apt-get update + apt-get upgrade are back-to-back) don't interleave.
{ printf '%s %s %s\n' "\$ts" "${step}" "\$*"; } >> "${_orch_call_log}"
sleep 1
exit 0
EOF
    chmod 0755 "$out"
}

# _orch_bind_stub TARGET STEP_NAME — install a stub for STEP_NAME and
# bind-mount it over TARGET. Bind-mount (rather than mv-aside) for all
# four paths so cleanup is a single strategy (umount); a kernel reboot
# severs all bindss if the probe is killed mid-run, leaving /usr in its
# original state.
_orch_bind_stub() {
    local target="$1" step="$2"
    if [[ ! -e "$target" ]]; then
        _orch_fail "orchestrator probe: stub target missing: $target (capability gate should have caught this)"
    fi
    local stub="$_orch_stub_dir/${step}.sh"
    _orch_write_stub "$stub" "$step"
    if ! mount --bind "$stub" "$target"; then
        _orch_fail "orchestrator probe: mount --bind of $step stub onto $target failed"
    fi
    _orch_active_binds+=("$target")
}

# _orch_restore — paired with _orch_bind_stub. Idempotent so the EXIT
# trap can call it safely even if installation failed partway through.
# set +e for the duration so one failed umount doesn't prevent the rest
# from being unmounted (each call is independent kernel state).
_orch_restore() {
    local saved_e=""
    case "$-" in *e*) saved_e=1 ;; esac
    set +e
    local i target
    # Reverse order — last mounted is first unmounted, mirroring a stack
    # discipline so any nested bind (none today, but defensive) unwinds
    # in the right direction.
    for (( i = ${#_orch_active_binds[@]} - 1; i >= 0; i-- )); do
        target="${_orch_active_binds[$i]}"
        # Two-step: try a clean umount first; fall back to lazy if a
        # process is still holding the mount (orchestrator should have
        # exited, but the transient unit's --collect may lag).
        umount "$target" 2>/dev/null \
            || umount -l "$target" 2>/dev/null \
            || true
    done
    _orch_active_binds=()
    [[ -n "$saved_e" ]] && set -e
    return 0
}

# _orch_state_get FIELD — read FIELD from the orchestrator state JSON
# and print its value. Always exits 0: empty string for missing file,
# null field, or parse error. Parse errors during a poll mean the
# orchestrator's atomic-write rename has not landed yet — treat as
# not-ready-yet and re-poll. Under set -e a non-zero rc from the
# python child would exit the subshell, so the swallow is required.
_orch_state_get() {
    local field="$1"
    [[ -f "$_orch_state_file" ]] || { printf ''; return 0; }
    python3 - "$_orch_state_file" "$field" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(0)
v = d.get(sys.argv[2])
print('' if v is None else v)
PY
}

# _orch_dump_diagnostics — log dump on probe failure or timeout.
# Inlines the state file, the marker dir, the sequence log, mount-
# namespace evidence, the orchestrator + webconfig unit journals, and
# stub layout into both the durable on-disk run.log and the serial
# console.
#
# Durability: run.sh redirects stdout/stderr through `tee -a run.log
# /dev/console`. fail() in run.sh issues `systemctl poweroff` before
# anything written via that tee has a chance to flush — so the
# inherited stdout cannot be trusted to land. We open a second fd
# directly on STATE_DIR/run.log, redirect all dump output through it,
# then sync. inspect_guest_state() in feed/test/image-boot.sh copies
# run.log into the qemu-logs artifact post-mortem, so anything written
# here survives the VM poweroff. A best-effort copy to /dev/console
# keeps live-watching usable when the race happens to be wide enough.
#
# set -e / set -u relaxation: many of the commands below can exit
# non-zero on missing paths, empty pipelines, or unset vars in
# unexpected probe states. The dump must never short-circuit; we
# unconditionally return 0 and reset shell options on the way out.
_orch_diag_done=0
_orch_dump_diagnostics() {
    # Don't re-dump if an explicit _orch_fail call already produced one.
    [[ "${_orch_diag_done:-0}" -eq 1 ]] && return 0
    _orch_diag_done=1

    local _diag_saved_e="" _diag_saved_u=""
    case "$-" in *e*) _diag_saved_e=1 ;; esac
    case "$-" in *u*) _diag_saved_u=1 ;; esac
    set +eu

    local diag_log="${STATE_DIR:-/var/lib/airplanes-boot-smoke}/run.log"

    # Open a direct append fd on run.log so the dump bypasses the
    # inherited tee pipeline. We MUST NOT let the `2>/dev/null` here
    # apply to the calling shell's stderr — `exec` with no command
    # silently makes redirections permanent, so a bare
    # `exec 7>>FILE 2>/dev/null` rewires fd 2 to /dev/null for the
    # rest of run.sh, which silences fail()'s "FAIL: ..." line on
    # the next assertion. Group the open in a `{ ... } 2>/dev/null`
    # so the stderr redirection scopes to the group only, while the
    # exec inside (with no `2>...` of its own) only changes fd 7.
    # If the open fails (read-only fs, ENOSPC), fall back to stdout
    # — explicitly redirected to /dev/null for fd 2 inside its own
    # group so the fallback exec doesn't leak the redirection either.
    { exec 7>>"$diag_log"; } 2>/dev/null \
        || { exec 7>&1; } 2>/dev/null
    # Mirror to /dev/console best-effort; same scoping discipline.
    { exec 8>>/dev/console; } 2>/dev/null \
        || { exec 8>/dev/null; } 2>/dev/null

    _orch_diag_emit() {
        local line
        for line in "$@"; do
            printf '%s\n' "$line" >&7 || true
            printf '%s\n' "$line" >&8 || true
        done
    }
    _orch_diag_run() {
        # Stream command output via fd 7 (durable run.log) and fd 8
        # (console, best-effort). Streaming rather than capture-to-var
        # so a huge `journalctl` payload doesn't consume probe memory.
        # `|| true` keeps a non-zero rc from tripping set -e in our
        # caller (we already relaxed errexit; defensive belt+braces).
        { "$@" 2>&1 | tee /dev/fd/8 >&7; } || true
    }

    _orch_diag_emit "image-probe: orchestrator diagnostics ---"

    # State file.
    if [[ -n "${_orch_state_file:-}" && -f "${_orch_state_file:-}" ]]; then
        _orch_diag_emit "image-probe: state file ($_orch_state_file):"
        _orch_diag_run cat "$_orch_state_file"
    else
        _orch_diag_emit "image-probe: state file absent (${_orch_state_file:-})"
    fi

    # Marker dir.
    if [[ -n "${_orch_marker_dir:-}" && -d "${_orch_marker_dir:-}" ]]; then
        _orch_diag_emit "image-probe: marker dir contents:"
        _orch_diag_run ls -la "$_orch_marker_dir"
        local m
        shopt -s nullglob
        for m in "$_orch_marker_dir"/*.ok; do
            _orch_diag_emit "image-probe: --- $m ---"
            _orch_diag_run cat "$m"
        done
        shopt -u nullglob
    else
        _orch_diag_emit "image-probe: marker dir absent (${_orch_marker_dir:-})"
    fi

    # Sequence log.
    if [[ -n "${_orch_call_log:-}" && -f "${_orch_call_log:-}" ]]; then
        _orch_diag_emit "image-probe: sequence log:"
        _orch_diag_run cat "$_orch_call_log"
    fi

    # Bind-mount evidence: are the stubs visible to /this/ shell?
    # Each step's target is bind-mounted onto its absolute path; the
    # apparent bind status + fs id + inode catches a silent unmount.
    _orch_diag_emit "image-probe: bind-mount evidence (probe-side):"
    _orch_diag_run mount
    local _t
    for _t in "${_orch_apt_get:-}" "${_orch_feed_update:-}" \
              "${_orch_webconfig_update:-}" "${_orch_runtime_update:-}"; do
        [[ -n "$_t" ]] || continue
        _orch_diag_emit "  target: $_t"
        _orch_diag_run stat -Lc '    stat: %n dev=%d ino=%i mode=%a type=%F size=%s' "$_t"
        _orch_diag_run readlink -f "$_t"
        _orch_diag_run findmnt -T "$_t" -n -o TARGET,SOURCE,FSTYPE,OPTIONS
    done

    # Stub dir layout + content head (proves the bind-mount source is
    # actually a 0755 executable shell script, not e.g. a 0644 placeholder).
    if [[ -n "${_orch_stub_dir:-}" && -d "${_orch_stub_dir:-}" ]]; then
        _orch_diag_emit "image-probe: stub dir layout:"
        _orch_diag_run ls -la "$_orch_stub_dir"
        local s
        shopt -s nullglob
        for s in "$_orch_stub_dir"/*.sh; do
            _orch_diag_emit "image-probe: --- $s (head) ---"
            _orch_diag_run head -25 "$s"
        done
        shopt -u nullglob
    else
        _orch_diag_emit "image-probe: stub dir absent (${_orch_stub_dir:-})"
    fi

    # Mount-namespace check: probe-side vs PID1. systemd-run inherits
    # PID1's namespace; a mismatch here would explain bind-mounts being
    # invisible to the orchestrator. Also check /run mount options —
    # if /run is noexec, executing our stubs from within the same
    # filesystem fails at the kernel level regardless of mode bits.
    _orch_diag_emit "image-probe: mount-namespace + /run options:"
    _orch_diag_run readlink /proc/self/ns/mnt
    _orch_diag_run readlink /proc/1/ns/mnt
    _orch_diag_run findmnt -T /run -n -o TARGET,FSTYPE,OPTIONS

    # Re-run the same checks from inside a transient systemd-run unit
    # — same mechanism the orchestrator uses to start. If the bind-
    # mounts or stub permissions look different here, mount-namespace
    # divergence is the root cause. --pipe so the output streams back
    # to our fd 7; --collect so the unit GCs cleanly; --wait so we get
    # the output before continuing.
    _orch_diag_emit "image-probe: transient-unit perspective (systemd-run --pipe --wait --collect):"
    # `timeout 15s` around systemd-run: if the failure mode is
    # systemd/dbus/transient-unit startup itself (e.g. dbus broker
    # wedged, transient unit can't start), --wait would hang
    # indefinitely and the rest of the dump (journals, end marker,
    # sync) would never run. 15s is generous compared to the actual
    # ns/mnt + stat + findmnt block this runs.
    {
        # shellcheck disable=SC2016  # vars are expanded inside the transient unit, not at quoting time.
        timeout 15s systemd-run --pipe --wait --collect --quiet \
            /bin/bash -c '
                set +e
                echo "ns/mnt: $(readlink /proc/self/ns/mnt)"
                echo "id: uid=$(id -u) gid=$(id -g) euid=$EUID"
                for t in /usr/bin/apt-get \
                         /usr/local/share/airplanes/update.sh \
                         /usr/local/lib/airplanes-webconfig/webconfig-self-update.sh \
                         /opt/airplanes-runtime/current/lib/runtime-self-update.sh; do
                    if [[ -x "$t" ]]; then xflag=x; else xflag=NOT-EXECUTABLE; fi
                    if [[ -e "$t" ]]; then eflag=exists; else eflag=MISSING; fi
                    echo "$t [$eflag $xflag]"
                    stat -Lc "  stat: dev=%d ino=%i mode=%a type=%F" "$t" 2>&1
                    findmnt -T "$t" -n -o TARGET,SOURCE,FSTYPE,OPTIONS 2>&1
                done
            ' 2>&1
        printf 'transient-unit rc=%d\n' "$?"
    } >&7
    # Echo a marker so the operator can see the transient-unit block
    # ended even if some commands inside it failed.
    _orch_diag_emit "image-probe: transient-unit perspective end"

    # Orchestrator unit + journal. Timeouts on every systemctl /
    # journalctl call: if dbus or journald itself is wedged, none of
    # these would otherwise return and the dump would hang past the
    # poweroff-imminent window. Budgets are tight on purpose; the
    # alternative is no diagnostics at all.
    _orch_diag_emit "image-probe: airplanes-update-orchestrator.service show:"
    _orch_diag_run timeout 5s systemctl show airplanes-update-orchestrator.service \
        --property=ExecStart,ActiveState,SubState,Result,ExecMainPID,ExecMainStatus,InvocationID
    _orch_diag_emit "image-probe: airplanes-update-orchestrator.service status:"
    _orch_diag_run timeout 5s systemctl status airplanes-update-orchestrator.service --no-pager --full
    _orch_diag_emit "image-probe: airplanes-update-orchestrator.service journal:"
    _orch_diag_run timeout 10s journalctl -u airplanes-update-orchestrator.service \
        --no-pager --since '10 min ago'

    _orch_diag_emit "image-probe: webconfig service journal (last 100):"
    _orch_diag_run timeout 10s journalctl -u airplanes-webconfig.service --no-pager -n 100

    _orch_diag_emit "image-probe: orchestrator diagnostics end ---"

    # Force durability. sync_file_range/fsync isn't directly reachable
    # from shell on an append fd; `sync` is a global flush.
    sync || true

    # Close our private fds. Same scoping rule as the open above —
    # group the `2>/dev/null` so we don't leak a permanent stderr
    # redirection into the calling shell.
    { exec 7>&-; } 2>/dev/null || true
    { exec 8>&-; } 2>/dev/null || true

    [[ -n "$_diag_saved_e" ]] && set -e
    [[ -n "$_diag_saved_u" ]] && set -u
    return 0
}

# _orch_fail MSG — dump diagnostics with mount evidence still in place,
# then unwind binds, then defer to run.sh's fail() (which writes the
# failure file, syncs, and powers off). All explicit assertion
# failures in the probe (and its _orch_bind_stub setup helper) MUST
# route through this so the dump always runs before poweroff.
_orch_fail() {
    local msg="$1"
    _orch_dump_diagnostics
    _orch_restore
    fail "$msg"
}

# _orch_capability_decision CHANNEL — decide what to do when the
# orchestrator surface is partial. Returns one of:
#   proceed
#   skip
#   fail:trampoline-missing
#   fail:overlay-binary-missing
#   fail:unknown-channel
#
# Asymmetry:
#   - Trampoline is image-owned (stage 06d), always present on every
#     channel. Its absence is a hard regression regardless of channel.
#   - Overlay binary ships in the runtime tag baked into the image.
#     Dev: must be present (config-dev pins a runtime tag that carries
#     the orchestrator). Stable: may be absent until a stable runtime
#     release ships with it — skip cleanly.
#   - Unknown channel (release-channel file missing/garbled): treat as
#     hard fail; the file is image-owned and stage 06 enforces the
#     allowlist {stable, dev}.
_orch_capability_decision() {
    local channel="$1"
    local trampoline_present=0 binary_present=0
    [[ -x "$_orch_trampoline" ]] && trampoline_present=1
    [[ -x "$_orch_binary" ]] && binary_present=1

    # Trampoline absence is always a fail — it's image-owned and
    # always present after stage 06d, on every channel.
    if (( trampoline_present == 0 )); then
        echo "fail:trampoline-missing"; return 0
    fi

    case "$channel" in
        dev)
            if (( binary_present == 1 )); then
                echo proceed; return 0
            fi
            echo "fail:overlay-binary-missing"; return 0
            ;;
        stable)
            if (( binary_present == 1 )); then
                echo proceed; return 0
            fi
            echo skip; return 0
            ;;
        *)
            echo "fail:unknown-channel"; return 0
            ;;
    esac
}

# _orch_run_probe COOKIEJAR — drive the orchestrator end-to-end. Caller
# provides a cookie jar already authenticated against webconfig (via
# the SSE probe's /api/setup). The probe body runs in a subshell so
# the EXIT trap we install doesn't leak into the sourced extra-probe
# parent shell. Channel-asymmetric capability gate: dev fails on a
# missing overlay binary (the dev runtime tag is bumped to carry it);
# stable skips cleanly until a runtime release ships with the
# orchestrator.
_orch_run_probe() {
    local cookiejar="$1"
    local channel
    channel="$(cat /etc/airplanes/release-channel 2>/dev/null || echo unknown)"

    local decision
    decision="$(_orch_capability_decision "$channel")"
    case "$decision" in
        proceed) ;;
        skip)
            echo "image-probe: orchestrator probe skipped (channel=$channel; overlay binary not yet present at $_orch_binary)"
            return 0
            ;;
        fail:trampoline-missing)
            _orch_fail "orchestrator probe: trampoline missing on channel=$channel: $_orch_trampoline (image regression — stage 06d should always lay this down)"
            ;;
        fail:overlay-binary-missing)
            _orch_fail "orchestrator probe: overlay orchestrator binary missing on channel=$channel: $_orch_binary (runtime tag bumped without orchestrator? config-dev or runtime release missed it)"
            ;;
        fail:unknown-channel)
            _orch_fail "orchestrator probe: /etc/airplanes/release-channel content '$channel' not in allowlist {stable, dev} (stage 06 should enforce this — file missing or corrupt?)"
            ;;
    esac

    echo "image-probe: orchestrator e2e probe starting (channel=$channel)"

    # Run the actual probe body in a subshell. extra-probe.sh is
    # sourced by run.sh, so a `trap ... EXIT` set in this process
    # would replace any EXIT trap in the caller and fire at run.sh's
    # exit. The subshell isolates the trap and the exit-on-fail
    # semantics; on subshell exit fail() inside it has already poweroffd
    # the VM so propagation isn't load-bearing, but defensively we
    # check rc and bail if the subshell exits non-zero for any other
    # reason.
    (
        # Arm the diagnostic + restore trap before ANY other action so
        # an unexplicit failure (set -e tripping mktemp, an unguarded
        # command, etc.) unwinds cleanly with a dump. Dump first,
        # restore second: the bind-mount state itself is part of the
        # evidence for problem-2-class failures; unmounting before
        # dumping erases it. Subshell-scoped so it doesn't leak into
        # the extra-probe parent shell. Explicit assertion failures
        # route through _orch_fail (which sets _orch_diag_done) so
        # this trap only fires for unexpected exits and doesn't
        # double-dump.
        trap '_orch_dump_diagnostics; _orch_restore' EXIT

        # Per-run unique paths. mktemp -d ensures a previous probe
        # attempt's markers can't satisfy our assertion trivially.
        _orch_marker_dir="$(mktemp -d /run/airplanes/test-orchestrator-markers.XXXXXX)"
        _orch_stub_dir="$(mktemp -d /run/airplanes/test-orchestrator-stubs.XXXXXX)"
        _orch_call_log="$_orch_marker_dir/call-log.txt"
        : > "$_orch_call_log"

        # Wipe the on-disk state file so any previous run's terminal
        # state can't pass our final assertion trivially. /run is
        # tmpfs and disappears across reboots; this guard protects
        # against a re-entry on the same boot (none today, but cheap
        # belt+braces).
        rm -f -- "$_orch_state_file"

        _orch_bind_stub "$_orch_apt_get"          apt
        _orch_bind_stub "$_orch_feed_update"      feed
        _orch_bind_stub "$_orch_webconfig_update" webconfig
        _orch_bind_stub "$_orch_runtime_update"   runtime

        # Stale-unit preflight. systemd-run --unit= fails if an
        # already-active unit with the same name exists; the API
        # would translate that to 409 (already_running), and we'd
        # report it but want a specific diagnostic here so the
        # operator knows the unit lingered from a prior run.
        local pre_state
        pre_state="$(systemctl show airplanes-update-orchestrator.service \
            --property=ActiveState --value 2>/dev/null || true)"
        case "$pre_state" in
            ''|inactive|dead)
                ;;
            *)
                _orch_fail "orchestrator probe: airplanes-update-orchestrator.service in unexpected pre-state '$pre_state' (--collect should have GC'd it; previous run leaked?)"
                ;;
        esac

        # Capture wall-clock window so the final-state mtime check
        # rejects any state file that predates our POST.
        local post_start_epoch
        post_start_epoch="$(date +%s)"
        local started=$SECONDS deadline=$(( SECONDS + 60 ))

        # `|| echo 000` so a curl-level failure (timeout, connection
        # refused, DNS, --max-time exhausted) doesn't trip set -e
        # before the case statement gets to surface it via _orch_fail.
        # 000 lands in the *) branch with a precise error message.
        local start_code
        start_code="$(curl --silent --show-error --output /dev/null \
            --write-out '%{http_code}' --max-time 10 \
            -X POST \
            -H 'Content-Type: application/json' \
            -H 'Origin: http://127.0.0.1' \
            -b "$cookiejar" \
            --data '{}' \
            http://127.0.0.1/api/orchestrator/start || echo 000)"
        case "$start_code" in
            202|200)
                ;;
            401|403)
                _orch_fail "orchestrator probe: /api/orchestrator/start returned $start_code (session cookie not honoured)"
                ;;
            409)
                _orch_fail "orchestrator probe: /api/orchestrator/start returned 409 (maintenanceUnits guard or unit-exists race — see diagnostics)"
                ;;
            503)
                _orch_fail "orchestrator probe: /api/orchestrator/start returned 503 (capability gate reported unavailable, but our pre-check above passed)"
                ;;
            *)
                _orch_fail "orchestrator probe: /api/orchestrator/start returned $start_code (want 202/200)"
                ;;
        esac

        # Poll the on-disk state file for up to 60s. Reading the file
        # is faster than HTTP polling and avoids any session-cookie
        # complications if the orchestrator's intra-run SIGHUP races
        # with a state-file read. We still re-validate the same view
        # via /api/orchestrator/state once after termination, below.
        # 60s budget: floor is roughly 5s (4 sleeps + apt double-call
        # overhead + per-step state writes); 60s gives ~12x slack.
        #
        # Terminal condition: status=failed at any step is terminal —
        # the orchestrator writes the failed status into the same step
        # field and exits, it never resets step to a synthetic
        # "failed" value. step=done is the happy-path terminal value.
        # Breaking on status=failed surfaces real failures within
        # seconds instead of after the full 60s budget, which keeps
        # the diagnostics dump's journal output fresh.
        local step status
        while (( SECONDS < deadline )); do
            if [[ ! -f "$_orch_state_file" ]]; then
                sleep 0.5
                continue
            fi
            step="$(_orch_state_get step)"
            status="$(_orch_state_get status)"
            # _orch_state_get returns empty on parse error — treat as
            # not-ready-yet and re-poll. The orchestrator writes
            # atomically (tmp + mv -f), but a poll racing the rename
            # could theoretically observe a missing target for one
            # cycle; the retry covers it without false-failing.
            case "$step:$status" in
                done:ok|*:failed)
                    break
                    ;;
            esac
            sleep 0.5
        done
        local elapsed=$(( SECONDS - started ))

        # Final state read for assertions. Re-read so any post-loop
        # atomic-write is visible.
        step="$(_orch_state_get step)"
        status="$(_orch_state_get status)"
        local err apt_irreversible
        err="$(_orch_state_get error)"
        apt_irreversible="$(_orch_state_get apt_irreversible)"

        # Mtime check: the state file must have been written after our
        # POST. Defends against a stale terminal state from a previous
        # run satisfying our assertions trivially (a missing wipe at
        # the top of this run would otherwise be invisible).
        if [[ -f "$_orch_state_file" ]]; then
            local state_mtime
            state_mtime="$(stat -c '%Y' -- "$_orch_state_file" 2>/dev/null || echo 0)"
            if (( state_mtime < post_start_epoch )); then
                _orch_fail "orchestrator probe: state file mtime=$state_mtime predates POST start=$post_start_epoch (stale state — wipe failed?)"
            fi
        fi

        if [[ "$step" != "done" ]]; then
            _orch_fail "orchestrator probe: terminal step=$step status=$status err=$err elapsed=${elapsed}s (want step=done within 60s)"
        fi
        if [[ "$status" != "ok" ]]; then
            _orch_fail "orchestrator probe: terminal status=$status (want ok)"
        fi
        if [[ -n "$err" ]]; then
            _orch_fail "orchestrator probe: terminal error field set: $err"
        fi
        # The apt step ran (the orchestrator chains apt-get update &&
        # upgrade and our stub returns 0 twice), so apt_irreversible
        # MUST be true in the final state. False here means the apt
        # step was either skipped (regression) or its irreversibility
        # flag wasn't recorded (state-file write order regression).
        # Python prints capitalised booleans through our shim — match
        # both common spellings to stay tolerant.
        case "$apt_irreversible" in
            true|True) ;;
            *) _orch_fail "orchestrator probe: apt_irreversible=$apt_irreversible in terminal state (want true; apt step skipped or flag not persisted?)" ;;
        esac

        # Per-phase marker files prove each stub was actually invoked
        # — the state file alone could (in theory) terminate at
        # step=done without all phases having run if a future refactor
        # short-circuits the sequencer.
        local missing="" s
        for s in apt feed webconfig runtime; do
            [[ -f "$_orch_marker_dir/${s}.ok" ]] || missing+=" $s"
        done
        if [[ -n "$missing" ]]; then
            _orch_fail "orchestrator probe: missing per-step marker(s):${missing}"
        fi

        # Call-count assertions on the sequence log. apt-get is
        # invoked twice (update, then upgrade); feed/webconfig/runtime
        # once each. A regression that drops one apt invocation
        # (chaining bug, --no-upgrade flag) would still leave
        # apt.ok present but only carry one line — without this
        # assertion it'd pass.
        # `grep -c` exits 1 on zero matches; `|| true` keeps the pipe
        # rc clean so set -e doesn't trip, and grep's own '0' output
        # is what we want without an extra echo 0 (which would emit
        # `0\n0` and trip the (( )) check downstream).
        local apt_calls feed_calls webconfig_calls runtime_calls
        apt_calls=$(grep -c '^[^ ]* apt ' "$_orch_call_log" 2>/dev/null || true)
        feed_calls=$(grep -c '^[^ ]* feed ' "$_orch_call_log" 2>/dev/null || true)
        webconfig_calls=$(grep -c '^[^ ]* webconfig ' "$_orch_call_log" 2>/dev/null || true)
        runtime_calls=$(grep -c '^[^ ]* runtime ' "$_orch_call_log" 2>/dev/null || true)
        : "${apt_calls:=0}" "${feed_calls:=0}" "${webconfig_calls:=0}" "${runtime_calls:=0}"
        if (( apt_calls != 2 )); then
            _orch_fail "orchestrator probe: apt was invoked $apt_calls times (want 2: 'update' + '-y upgrade')"
        fi
        if (( feed_calls != 1 )); then
            _orch_fail "orchestrator probe: feed stub was invoked $feed_calls times (want 1)"
        fi
        if (( webconfig_calls != 1 )); then
            _orch_fail "orchestrator probe: webconfig stub was invoked $webconfig_calls times (want 1)"
        fi
        if (( runtime_calls != 1 )); then
            _orch_fail "orchestrator probe: runtime stub was invoked $runtime_calls times (want 1)"
        fi

        # Sequence assertion: apt before feed before webconfig before
        # runtime. The bats coverage pins this for the orchestrator
        # script in isolation; we re-check here because a regression
        # in the trampoline or systemd-run plumbing could in principle
        # reorder the actual execution.
        #
        # `|| true` on each pipeline: pipefail is on (inherited from
        # run.sh's `set -euo pipefail`), and the grep|head|cut shape
        # has two failure modes that would otherwise trip set -e and
        # bypass _orch_fail — grep exits 1 on no-match (sequence-log
        # missing case below would never run), and head -1 closes the
        # pipe after one line so grep can also get SIGPIPE (rc=141)
        # on a matching but multi-line input. We want the assertions
        # to be the only place that fails.
        local apt_first feed_first wc_first rt_first
        apt_first=$(grep -n '^[^ ]* apt update$' "$_orch_call_log" | head -1 | cut -d: -f1 || true)
        feed_first=$(grep -n '^[^ ]* feed ' "$_orch_call_log" | head -1 | cut -d: -f1 || true)
        wc_first=$(grep -n '^[^ ]* webconfig ' "$_orch_call_log" | head -1 | cut -d: -f1 || true)
        rt_first=$(grep -n '^[^ ]* runtime ' "$_orch_call_log" | head -1 | cut -d: -f1 || true)
        if [[ -z "$apt_first" || -z "$feed_first" || -z "$wc_first" || -z "$rt_first" ]]; then
            _orch_fail "orchestrator probe: sequence log missing one of apt/feed/webconfig/runtime entries (log: $(cat "$_orch_call_log"))"
        fi
        if ! (( apt_first < feed_first && feed_first < wc_first && wc_first < rt_first )); then
            _orch_fail "orchestrator probe: step order wrong — apt=$apt_first feed=$feed_first webconfig=$wc_first runtime=$rt_first (want strict ascending)"
        fi

        # Runtime sanity bound. See the budget comment above.
        if (( elapsed > 60 )); then
            _orch_fail "orchestrator probe: elapsed=${elapsed}s exceeded 60s bound"
        fi

        # Wait for the transient unit to drain (--collect should GC it
        # within milliseconds; budget 30s for slow QEMU). Without this,
        # the HTTP cross-check and /health probe below could race
        # against the ExecStopPost HUP which fires AFTER the
        # orchestrator process exits — orchestrator state=done is
        # observable before ExecStopPost completes. Hard fail if the
        # drain doesn't happen — a stuck unit means the post-orchestrator
        # invariants the rest of the probe relies on are not
        # established and any later assertion would be racing.
        local unit_drain_deadline=$(( SECONDS + 30 )) unit_state=""
        while (( SECONDS < unit_drain_deadline )); do
            unit_state="$(systemctl show airplanes-update-orchestrator.service \
                --property=ActiveState --value 2>/dev/null || true)"
            case "$unit_state" in
                ''|inactive|dead)
                    break
                    ;;
            esac
            sleep 0.5
        done
        case "$unit_state" in
            ''|inactive|dead)
                ;;
            *)
                _orch_fail "orchestrator probe: transient unit still ActiveState=$unit_state after 30s drain budget (ExecStopPost hung? --collect not honoured?)"
                ;;
        esac

        # Cross-check via the HTTP route — proves the airplanes-webconfig
        # service account can read /run/airplanes/orchestrator.state
        # (mode/owner regression) and that the route is wired. Direct
        # file read above used root; this is the production posture.
        # The handler's contract is "forward the file body verbatim",
        # so compare the response body byte-for-byte with the state
        # file. cmp catches handler regressions that strip fields
        # (apt_irreversible, started_at, error) or reformat the JSON.
        local state_http body_file
        body_file="$(mktemp)"
        state_http="$(curl --silent --show-error --output "$body_file" \
            --write-out '%{http_code}' --max-time 10 \
            -b "$cookiejar" http://127.0.0.1/api/orchestrator/state)"
        if [[ "$state_http" != "200" ]]; then
            echo "image-probe: /api/orchestrator/state body: $(cat "$body_file" 2>/dev/null)"
            rm -f "$body_file"
            _orch_fail "orchestrator probe: GET /api/orchestrator/state returned $state_http (want 200; service-account read of state file broken?)"
        fi
        if ! cmp -s "$body_file" "$_orch_state_file"; then
            echo "image-probe: state file:"
            cat "$_orch_state_file" 2>/dev/null || true
            echo "image-probe: HTTP body:"
            cat "$body_file" 2>/dev/null || true
            rm -f "$body_file"
            _orch_fail "orchestrator probe: /api/orchestrator/state body did not match state file byte-for-byte (handler regressed away from the verbatim-forward contract)"
        fi
        rm -f "$body_file"

        # Webconfig is still responsive after the orchestrator's HUPs.
        _wcu_health_200 \
            || _orch_fail "orchestrator probe: /health did not return 200 after orchestrator finished + unit drained"

        # SIGHUP proof: step_feed_hup in the orchestrator and the
        # systemd-run ExecStopPost both send SIGHUP to webconfig. The
        # schema cache reload logs an identifiable line on each HUP.
        # Without this check, a regression that drops either HUP would
        # still pass (webconfig keeps serving /health regardless). We
        # don't pin the exact count — systemd ordering between the
        # orchestrator's intra-run kill and ExecStopPost can collapse
        # under tight timing — but at least one entry must land within
        # the probe window.
        if ! journalctl -u airplanes-webconfig.service \
                --no-pager --since "@$post_start_epoch" 2>&1 \
                | grep -qiE 'sighup|schema.*reload|reloading'; then
            _orch_fail "orchestrator probe: webconfig journal shows no SIGHUP/schema-reload entries since orchestrator POST (feed-step HUP and/or ExecStopPost HUP did not fire?)"
        fi

        # Tear down — paired with the trap above. Drop the trap
        # explicitly so the diagnostic dump only fires on failure.
        _orch_restore
        # Verify cleanup landed — a leaked bind on /usr/bin/apt-get
        # would break the next apt operation on this VM.
        local leaked=""
        for s in "$_orch_apt_get" "$_orch_feed_update" \
                 "$_orch_webconfig_update" "$_orch_runtime_update"; do
            if mountpoint -q "$s" 2>/dev/null; then
                leaked+=" $s"
            fi
        done
        if [[ -n "$leaked" ]]; then
            _orch_fail "orchestrator probe: bind mount(s) leaked after restore:${leaked}"
        fi
        trap - EXIT

        echo "image-probe: orchestrator e2e probe passed (elapsed=${elapsed}s, all 4 markers + sequence + HTTP cross-check)"
    )
    local sub_rc=$?
    if (( sub_rc != 0 )); then
        # The subshell exited non-zero. Distinguish two cases:
        #
        #   A. The subshell called _orch_fail explicitly. In that path
        #      fail() in run.sh already wrote the real failure message
        #      to $STATE_DIR/failure and called `systemctl poweroff;
        #      exit 1` — but `exit 1` exits the SUBSHELL, not run.sh,
        #      so we get here with sub_rc=1 and the failure file
        #      already populated. Re-calling _orch_fail here would
        #      overwrite the specific failure message with a generic
        #      one. Don't do that — let the in-flight poweroff carry
        #      the real message out.
        #
        #   B. Something inside the subshell tripped set -e without
        #      going through _orch_fail (e.g. an unguarded pipefail
        #      or command substitution failure). The EXIT trap ran
        #      the dump, but no failure-file was written. Surface a
        #      generic message via fail() in this case so the harness
        #      doesn't silently report a successful smoke after the
        #      missed assertion.
        #
        # Detection: $STATE_DIR/failure exists iff fail() ran. We
        # don't need to read its content — its existence alone is
        # the signal.
        local failure_marker="${STATE_DIR:-/var/lib/airplanes-boot-smoke}/failure"
        if [[ -f "$failure_marker" ]]; then
            # _orch_fail already routed through fail(); poweroff is
            # in flight; nothing useful to add. Return so we don't
            # clobber the existing message or trigger a second dump.
            return 0
        fi
        _orch_fail "orchestrator probe: subshell exited rc=$sub_rc unexpectedly (set -e tripped outside _orch_fail; see dump)"
    fi
}

# ---------------------------------------------------------------------------

echo "image-probe: starting image-side assertions"

# Runtime-overlay symlink chain assertions. The decoder units,
# render-status, decoder binaries, tar1090/graphs1090 surfaces and
# lighttpd conf-available snippets all resolve through
# /opt/airplanes-runtime/current/ → versioned release dir.
if [[ -d /opt/airplanes-runtime ]]; then
    _runtime_link="$(readlink /etc/systemd/system/readsb.service 2>/dev/null || true)"
    [[ "$_runtime_link" == "/opt/airplanes-runtime/current/systemd/readsb.service" ]] \
        || fail "readsb.service symlink unexpected: $_runtime_link"

    [[ "$(readlink /etc/systemd/system/airplanes-runtime-update-recover.service 2>/dev/null)" \
        == "/opt/airplanes-runtime/current/systemd/airplanes-runtime-update-recover.service" ]] \
        || fail "airplanes-runtime-update-recover.service symlink unexpected"
    systemctl is-enabled airplanes-runtime-update-recover.service >/dev/null \
        || fail "airplanes-runtime-update-recover.service not enabled"

    # Two-hop lighttpd chain: conf-enabled (image-owned) → conf-available
    # (overlay-owned absolute) → release dir. Just assert the final target
    # resolves; -e through the symlink chain proves both hops.
    [[ -e /etc/lighttpd/conf-enabled/89-airplanes-978.conf ]] \
        || fail "lighttpd conf-enabled 89-airplanes-978.conf does not resolve through overlay"
    [[ -e /etc/lighttpd/conf-enabled/88-tar1090.conf ]] \
        || fail "lighttpd conf-enabled 88-tar1090.conf does not resolve through overlay"
    [[ -e /etc/lighttpd/conf-enabled/88-graphs1090.conf ]] \
        || fail "lighttpd conf-enabled 88-graphs1090.conf does not resolve through overlay"

    # decoder binary symlinks (both → readsb; airplanes-978 is a symlink,
    # not a hardlink, per the v1 layout).
    [[ "$(readlink /usr/bin/readsb 2>/dev/null)" == "/opt/airplanes-runtime/current/bin/readsb" ]] \
        || fail "/usr/bin/readsb symlink unexpected"
    [[ "$(readlink /usr/bin/airplanes-978 2>/dev/null)" == "/opt/airplanes-runtime/current/bin/readsb" ]] \
        || fail "/usr/bin/airplanes-978 should symlink to current/bin/readsb"
    [[ "$(readlink /usr/bin/dump978-fa 2>/dev/null)" == "/opt/airplanes-runtime/current/bin/dump978-fa" ]] \
        || fail "/usr/bin/dump978-fa symlink unexpected"

    # Runtime manifest pointer. On a fresh-flashed image (before the first
    # runtime self-update has fired) this is a regular-file copy of the
    # baked release's manifest, written by install.sh --build-mode. After
    # the first on-device runtime self-update it gets replaced (mv -Tf) by
    # a symlink to /opt/airplanes-runtime/current/manifest.json so the
    # pointer auto-follows current. Boot-smoke runs against a fresh image
    # so the regular-file case is what we see here; we just need the file
    # to be present and parseable.
    [[ -e /etc/airplanes/runtime-manifest.json ]] \
        || fail "/etc/airplanes/runtime-manifest.json missing"
    jq -e '.version' /etc/airplanes/runtime-manifest.json >/dev/null 2>&1 \
        || fail "/etc/airplanes/runtime-manifest.json is not parseable JSON with .version"

    # Public key shipped and well-formed.
    [[ -r /usr/share/airplanes/runtime-release.pub ]] \
        || fail "/usr/share/airplanes/runtime-release.pub missing"
    head -1 /usr/share/airplanes/runtime-release.pub | grep -q "minisign public key" \
        || fail "runtime-release.pub header malformed"

    # minisign actually parses the shipped key (no binary surprises).
    command -v minisign >/dev/null 2>&1 \
        || fail "minisign apt package not installed"
fi

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

# Update-orchestrator launch path is image-owned (stage 06d) and must
# exist on every image regardless of which runtime-overlay tag is baked
# in. The trampoline exec()s the overlay-shipped orchestrator binary
# after a capability check; webconfig's sudoers entry pins this path.
assert_file /usr/local/lib/airplanes-webconfig/start-orchestrator.sh
[[ -x /usr/local/lib/airplanes-webconfig/start-orchestrator.sh ]] \
    || fail "/usr/local/lib/airplanes-webconfig/start-orchestrator.sh is not executable"

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
sse_first_pass=0

curl --silent --show-error --max-time 5 \
    http://127.0.0.1/api/state > "$sse_state_out" || true

# Re-entrant: the webconfig-upgrade-qemu variant reboots from inside this
# probe and re-sources us afterwards; by then /api/setup has already moved
# the device to "initialized" and the SSE password-setup+stream path is no
# longer applicable. Skip it cleanly — the persistence path below probes
# /health and the running service, which is what matters for a second pass.
if grep -q '"state":"uninitialized"' "$sse_state_out"; then
    sse_first_pass=1
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

# Orchestrator e2e — only on the first pass (when the SSE setup just
# initialised the device and the cookie jar holds a fresh session).
# Skipping on the second pass avoids racing against a possibly-restarted
# webconfig from the upgrade variant, and there's no coverage gain
# repeating the same check across a reboot. The probe self-gates on
# trampoline + overlay-binary presence so a stable boot whose pinned
# runtime predates the orchestrator stays green.
if (( sse_first_pass == 1 )); then
    _orch_run_probe "$sse_cookiejar"
fi

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
