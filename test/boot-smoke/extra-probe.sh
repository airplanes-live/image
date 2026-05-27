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
# Update-orchestrator e2e probe — drives POST /api/orchestrator/start with
# every sub-helper stubbed out at its absolute path so the orchestrator's
# two-phase sequencing (apt → runtime) is exercised end-to-end without
# actually mutating apt / runtime. The bats coverage at
# test/runtime-overlay/test_orchestrator_sequence.bats exercises the
# orchestrator script in isolation; this probe exercises the click-flow
# (HTTP -> sudoers -> systemd-run -> orchestrator -> state-file) the SPA
# uses, which the bats coverage cannot reach.
#
# Stubs are installed at the three absolute paths the orchestrator
# invokes by default (no env override is possible because systemd-run's
# sudoers-pinned argv uses env_reset and the production defaults are
# hard-coded as absolute paths in the orchestrator script itself).
# All three use bind-mount (not move-aside) so cleanup is a single
# umount-in-reverse strategy and a probe abort leaves /usr/local/...
# intact via the kernel's mount table even if _orch_restore never runs:
#
#   /usr/bin/apt-get
#   /usr/local/share/airplanes/update.sh
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

# Absolute paths the orchestrator invokes for each step. Kept in sync with
# the script's defaults block.
_orch_apt_get=/usr/bin/apt-get
# _orch_feed_update removed — the orchestrator no longer has a feed step.
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
    # Bind mounts inherit the source mount's VFS flags. /run is
    # mounted nosuid,nodev,noexec by stage 06a's fstab line (and
    # trixie's default tmp.mount carries the same flags), so on
    # modern kernels (>=2.6.20) `access(file, X_OK)` returns EACCES
    # for a bind-mounted stub sourced from /run. The orchestrator
    # gates each step on `[[ -x "$target" ]]` / `command -v
    # "$target"` (both call access(X_OK)), so without this remount
    # step_apt silently skips (its missing-path branch returns 0)
    # and step_feed explicitly returns 1 — the exact failure shape
    # boot-smoke surfaced on dev-arm64.
    #
    # Add target to _orch_active_binds BEFORE the remount so a
    # failed remount still unwinds via _orch_restore (umount).
    # Spell out nosuid,nodev,exec rather than relying on libmount
    # preserving inherited nosuid/nodev while only clearing noexec:
    # being explicit avoids surprises across util-linux versions.
    # Follow up with a probe-side `[[ -x ]]` to catch a remount
    # that returned 0 but failed to clear noexec for any reason.
    _orch_active_binds+=("$target")
    if ! mount -o remount,bind,nosuid,nodev,exec "$target" 2>/dev/null; then
        _orch_fail "orchestrator probe: mount -o remount,bind,nosuid,nodev,exec on $target failed (kernel rejected exec override; bind would inherit noexec from /run and step gate would fail)"
    fi
    if [[ ! -x "$target" ]]; then
        _orch_fail "orchestrator probe: post-remount bind $target still reads as not-executable (noexec clear apparently silently no-op'd; access(X_OK) returns EACCES)"
    fi
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

    # Periodic sync helper: each major section calls this so that even
    # if init starts killing processes mid-dump, what's already on
    # run.log is durable on the virtio-blk-backed .img file (the
    # harness mounts the .img post-mortem to extract run.log). `sync`
    # is cheap on a small file, and the dump targets a few KB total.
    _orch_diag_flush() {
        sync 2>/dev/null || true
    }

    _orch_diag_emit "image-probe: orchestrator diagnostics ---"
    _orch_diag_flush

    # State file.
    if [[ -n "${_orch_state_file:-}" && -f "${_orch_state_file:-}" ]]; then
        _orch_diag_emit "image-probe: state file ($_orch_state_file):"
        _orch_diag_run cat "$_orch_state_file"
    else
        _orch_diag_emit "image-probe: state file absent (${_orch_state_file:-})"
    fi
    _orch_diag_flush

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
    _orch_diag_flush

    # Sequence log.
    if [[ -n "${_orch_call_log:-}" && -f "${_orch_call_log:-}" ]]; then
        _orch_diag_emit "image-probe: sequence log:"
        _orch_diag_run cat "$_orch_call_log"
    fi
    _orch_diag_flush

    # Bind-mount evidence: are the stubs visible to /this/ shell?
    # Each step's target is bind-mounted onto its absolute path; the
    # apparent bind status + fs id + inode catches a silent unmount.
    _orch_diag_emit "image-probe: bind-mount evidence (probe-side):"
    _orch_diag_run mount
    local _t
    for _t in "${_orch_apt_get:-}" \
              "${_orch_runtime_update:-}"; do
        [[ -n "$_t" ]] || continue
        _orch_diag_emit "  target: $_t"
        _orch_diag_run stat -Lc '    stat: %n dev=%d ino=%i mode=%a type=%F size=%s' "$_t"
        _orch_diag_run readlink -f "$_t"
        _orch_diag_run findmnt -T "$_t" -n -o TARGET,SOURCE,FSTYPE,OPTIONS
    done
    _orch_diag_flush

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
    _orch_diag_flush

    # Mount-namespace check: probe-side vs PID1. systemd-run inherits
    # PID1's namespace; a mismatch here would explain bind-mounts being
    # invisible to the orchestrator. Also check /run mount options —
    # if /run is noexec, executing our stubs from within the same
    # filesystem fails at the kernel level regardless of mode bits.
    _orch_diag_emit "image-probe: mount-namespace + /run options:"
    _orch_diag_run readlink /proc/self/ns/mnt
    _orch_diag_run readlink /proc/1/ns/mnt
    _orch_diag_run findmnt -T /run -n -o TARGET,FSTYPE,OPTIONS
    _orch_diag_flush

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
    _orch_diag_flush

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
    _orch_diag_flush

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
        # All three live under /run (tmpfs, sized at 06a) — stage 06a
        # mounts /run noexec, which we deal with via an explicit
        # `mount -o remount,bind,exec` after each bind (see
        # _orch_bind_stub). Both /run and the trixie default
        # tmp.mount carry noexec, so picking a different parent
        # filesystem wouldn't help; the remount is the universal fix.
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
        _orch_bind_stub "$_orch_runtime_update"   runtime

        # Cross-namespace visibility check: the orchestrator runs in a
        # transient systemd unit, which today inherits PID1's mount
        # namespace — but a future systemd or sudoers change that
        # adds PrivateMounts/MountFlags would silently make our
        # bind-mounts invisible. Capture each target's dev:ino as
        # seen from this shell, then re-stat from inside ONE
        # systemd-run --pipe --wait --collect bash (one round trip
        # for all four targets, not four), and assert dev:ino match
        # AND [[ -x ]] passes there. A mismatch surfaces an exact
        # diagnostic before the POST instead of an opaque step
        # failure 5–10 seconds later.
        local _t expect_payload="" line
        for _t in "$_orch_apt_get" \
                  "$_orch_runtime_update"; do
            line="$(stat -Lc '%d:%i' -- "$_t" 2>/dev/null || true)"
            if [[ -z "$line" ]]; then
                _orch_fail "orchestrator probe: cross-ns check: stat failed for $_t (bind-mount setup race?)"
            fi
            expect_payload+="$_t $line"$'\n'
        done

        local transient_payload
        # shellcheck disable=SC2016  # $TARGETS expands inside the transient unit, not at quoting time.
        transient_payload="$(timeout 15s systemd-run --pipe --wait --collect --quiet \
            --setenv=TARGETS="$_orch_apt_get $_orch_runtime_update" \
            /bin/bash -c '
                set +e
                for t in $TARGETS; do
                    di="$(stat -Lc "%d:%i" -- "$t" 2>/dev/null || echo unknown)"
                    if [[ -x "$t" ]]; then xok=1; else xok=0; fi
                    printf "%s %s %s\n" "$t" "$di" "$xok"
                done
            ' 2>/dev/null || true)"
        if [[ -z "$transient_payload" ]]; then
            _orch_fail "orchestrator probe: cross-ns check: systemd-run transient unit returned no output (15s timeout? unit failed to start?)"
        fi

        # Parse both payloads and assert per-target. expect_payload
        # has "path dev:ino" per line; transient_payload has
        # "path dev:ino xok" per line. Match on path.
        local exp_path exp_di
        while read -r exp_path exp_di; do
            [[ -z "$exp_path" ]] && continue
            local got_di="" got_xok=""
            local tp_path tp_di tp_xok
            while read -r tp_path tp_di tp_xok; do
                if [[ "$tp_path" == "$exp_path" ]]; then
                    got_di="$tp_di"
                    got_xok="$tp_xok"
                    break
                fi
            done <<<"$transient_payload"
            if [[ -z "$got_di" ]]; then
                _orch_fail "orchestrator probe: cross-ns check on $exp_path: transient unit did not report this path (payload: $transient_payload)"
            fi
            if [[ "$got_di" != "$exp_di" ]]; then
                _orch_fail "orchestrator probe: cross-ns check on $exp_path: probe-side dev:ino=$exp_di but transient unit sees $got_di (mount-namespace divergence — orchestrator will not see our stubs)"
            fi
            if [[ "$got_xok" != "1" ]]; then
                _orch_fail "orchestrator probe: cross-ns check on $exp_path: transient unit reports [[ -x ]] false despite remount,exec (noexec carry-through; orchestrator step gate will reject this target)"
            fi
        done <<<"$expect_payload"

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
        for s in apt runtime; do
            [[ -f "$_orch_marker_dir/${s}.ok" ]] || missing+=" $s"
        done
        if [[ -n "$missing" ]]; then
            _orch_fail "orchestrator probe: missing per-step marker(s):${missing}"
        fi
        # Feed + webconfig ship inside the runtime overlay now — the
        # orchestrator has no separate feed step, so a feed marker must NOT
        # appear.
        if [[ -f "$_orch_marker_dir/feed.ok" ]]; then
            _orch_fail "orchestrator probe: unexpected feed.ok marker (orchestrator should have no feed step)"
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
        local apt_calls runtime_calls
        apt_calls=$(grep -c '^[^ ]* apt ' "$_orch_call_log" 2>/dev/null || true)
        runtime_calls=$(grep -c '^[^ ]* runtime ' "$_orch_call_log" 2>/dev/null || true)
        : "${apt_calls:=0}" "${runtime_calls:=0}"
        if (( apt_calls != 2 )); then
            _orch_fail "orchestrator probe: apt was invoked $apt_calls times (want 2: 'update' + '-y upgrade')"
        fi
        if (( runtime_calls != 1 )); then
            _orch_fail "orchestrator probe: runtime stub was invoked $runtime_calls times (want 1)"
        fi

        # Sequence assertion: apt before runtime. The bats coverage pins this
        # for the orchestrator script in isolation; we re-check here because a
        # regression in the trampoline or systemd-run plumbing could in
        # principle reorder the actual execution. The orchestrator is now a
        # two-step sequence (apt → runtime); there is no feed step.
        #
        # `|| true` on each pipeline: pipefail is on (inherited from
        # run.sh's `set -euo pipefail`), and the grep|head|cut shape
        # has two failure modes that would otherwise trip set -e and
        # bypass _orch_fail — grep exits 1 on no-match (sequence-log
        # missing case below would never run), and head -1 closes the
        # pipe after one line so grep can also get SIGPIPE (rc=141)
        # on a matching but multi-line input. We want the assertions
        # to be the only place that fails.
        local apt_first rt_first
        apt_first=$(grep -n '^[^ ]* apt update$' "$_orch_call_log" | head -1 | cut -d: -f1 || true)
        rt_first=$(grep -n '^[^ ]* runtime ' "$_orch_call_log" | head -1 | cut -d: -f1 || true)
        if [[ -z "$apt_first" || -z "$rt_first" ]]; then
            _orch_fail "orchestrator probe: sequence log missing one of apt/runtime entries (log: $(cat "$_orch_call_log"))"
        fi
        if ! (( apt_first < rt_first )); then
            _orch_fail "orchestrator probe: step order wrong — apt=$apt_first runtime=$rt_first (want apt before runtime)"
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
        local _orch_health_code
        _orch_health_code="$(curl --silent --show-error --output /dev/null \
            --write-out '%{http_code}' --max-time 5 \
            http://127.0.0.1/health || echo 000)"
        [[ "$_orch_health_code" == "200" ]] \
            || _orch_fail "orchestrator probe: health endpoint returned $_orch_health_code after orchestrator finished + unit drained (want 200)"

        # The feed-step SIGHUP to webconfig is gone — the orchestrator no
        # longer has a feed step (feed-env schema changes now ride the runtime
        # overlay's atomic webconfig+feed swap), so there is no post-feed HUP
        # to assert here. The webconfig /health check above already proves the
        # service is responsive after the orchestrator run.

        # Tear down — paired with the trap above. Drop the trap
        # explicitly so the diagnostic dump only fires on failure.
        _orch_restore
        # Verify cleanup landed — a leaked bind on /usr/bin/apt-get
        # would break the next apt operation on this VM.
        local leaked=""
        for s in "$_orch_apt_get" \
                 "$_orch_runtime_update"; do
            if mountpoint -q "$s" 2>/dev/null; then
                leaked+=" $s"
            fi
        done
        if [[ -n "$leaked" ]]; then
            _orch_fail "orchestrator probe: bind mount(s) leaked after restore:${leaked}"
        fi
        trap - EXIT

        echo "image-probe: orchestrator e2e probe passed (elapsed=${elapsed}s, apt + runtime markers + sequence + HTTP cross-check)"
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
        #      already populated. We MUST stop run.sh's main flow
        #      here: any later assertion in extra-probe.sh (or
        #      run.sh) calling fail() would overwrite our specific
        #      failure-file content with a generic message. `exit 1`
        #      from a function defined in a sourced script exits the
        #      sourcing shell (run.sh), which preserves our message
        #      and lets the in-flight poweroff carry the VM out.
        #
        #   B. Something inside the subshell tripped set -e without
        #      going through _orch_fail (e.g. an unguarded pipefail
        #      or command substitution failure). The EXIT trap ran
        #      the dump, but no failure-file was written. Surface a
        #      generic message via _orch_fail in this case so the
        #      harness doesn't silently report a successful smoke
        #      after the missed assertion.
        #
        # Detection: $STATE_DIR/failure exists iff fail() ran. We
        # don't need to read its content — its existence alone is
        # the signal.
        local failure_marker="${STATE_DIR:-/var/lib/airplanes-boot-smoke}/failure"
        if [[ -f "$failure_marker" ]]; then
            # _orch_fail already wrote $STATE_DIR/failure and called
            # systemctl poweroff. Stop run.sh main flow so no later
            # fail() can overwrite the message.
            exit 1
        fi
        _orch_fail "orchestrator probe: subshell exited rc=$sub_rc unexpectedly (set -e tripped outside _orch_fail; see dump)"
    fi
}

# ---------------------------------------------------------------------------
# Runtime-overlay update + rollback probe (opt-in).
# ---------------------------------------------------------------------------
#
# Drives the REAL runtime-self-update.sh against synthetic LOCAL overlay
# releases staged by test/boot-smoke/lib/runtime-upgrade-helpers.sh — no GitHub
# release is touched. Two-pass via an own marker so the reboot-persistence leg
# survives the harness re-running the 'updated' phase:
#   pass 1: install GOOD vN+1 (assert convergence), install BROKEN vN+1
#           (assert rollback to the prior release), then reboot.
#   pass 2: assert the rolled-back GOOD release is still current after reboot
#           and the consumer services are active; done.
# Runs BEFORE the orchestrator stub probe, which bind-mounts a stub over
# runtime-self-update.sh — this probe needs the real helper.
_runtime_upgrade_marker_base() {
    cat /var/lib/airplanes-boot-smoke/runtime-upgrade-asset-base 2>/dev/null || true
}

# Drive runtime-self-update.sh against a local asset dir. Returns the helper's
# exit code. AIRPLANES_RUNTIME_RELEASE_ASSET_DIR makes the helper consume the
# staged signed asset set instead of downloading from GitHub; the baked pubkey
# was overridden to the test key in setup.sh so the synthetic
# SHA256SUMS.minisig verifies. AIRPLANES_RUNTIME_OVERLAY_TAG=local-assets pins
# the resolver to the local-assets path so channel/version resolution is
# bypassed and the manifest-version check accepts the synthetic version
# regardless of the image's release channel.
_runtime_drive_update() {
    local asset_dir="$1"
    # Health-gate deadline shortened from the production default (120s) to fit
    # the QEMU emulation budget. 90s leaves the GOOD release ample headroom to
    # converge under emulation (unit start + ~25s stability window + freshness),
    # while still capping the BROKEN release's freshness-timeout at 90s instead
    # of 120s. Combined with the 25m per-boot QEMU timeout, this keeps the two
    # update cycles plus the persistence reboot inside budget without KVM.
    AIRPLANES_RUNTIME_RELEASE_ASSET_DIR="$asset_dir" \
    AIRPLANES_RUNTIME_OVERLAY_TAG="local-assets" \
    AIRPLANES_RUNTIME_MIN_FREE_BYTES=0 \
    AIRPLANES_RUNTIME_HEALTH_DEADLINE=90 \
        /opt/airplanes-runtime/current/lib/runtime-self-update.sh
}

_runtime_current_version() {
    local cur
    cur="$(readlink -f /opt/airplanes-runtime/current 2>/dev/null || true)"
    printf '%s' "${cur##*/v}"
}

_runtime_upgrade_probe() {
    local asset_base
    asset_base="$(_runtime_upgrade_marker_base)"
    [[ -n "$asset_base" ]] || return 0  # variant not enabled

    local progress=/run/airplanes-boot-smoke-runtime-upgrade.progress
    local phase=""
    [[ -f "$progress" ]] && phase="$(cat "$progress" 2>/dev/null || true)"

    if [[ "$phase" == "rolled-back-rebooted" ]]; then
        # Pass 2 — verify the rolled-back release persisted across the reboot.
        echo "image-probe: runtime-upgrade pass 2 (post-reboot persistence)"
        local cur_ver
        cur_ver="$(_runtime_current_version)"
        [[ "$cur_ver" == "$_runtime_good_version" ]] \
            || fail "runtime-upgrade: after reboot current=v$cur_ver, expected the rolled-back good release v$_runtime_good_version"
        assert_service_healthy readsb.service
        assert_service_healthy airplanes-feed.service
        assert_service_healthy airplanes-webconfig.service
        echo "image-probe: runtime-upgrade reboot-persistence passed (current=v$cur_ver)"
        rm -f "$progress"
        return 0
    fi

    # Pass 1.
    echo "image-probe: runtime-upgrade pass 1 (GOOD then BROKEN)"

    local baseline_ver
    baseline_ver="$(_runtime_current_version)"
    echo "image-probe: runtime-upgrade baseline current=v$baseline_ver"

    # --- GOOD vN+1 : expect convergence -------------------------------------
    echo "image-probe: driving runtime-self-update to GOOD release"
    if ! _runtime_drive_update "$asset_base/good"; then
        cat /var/lib/airplanes-runtime-upgrade/upgrade-state 2>/dev/null >&2 || true
        journalctl -u readsb.service --no-pager -n 50 2>/dev/null >&2 || true
        fail "runtime-upgrade: GOOD update did not converge (helper exited non-zero)"
    fi
    _runtime_good_version="$(_runtime_current_version)"
    [[ "$_runtime_good_version" != "$baseline_ver" ]] \
        || fail "runtime-upgrade: current did not flip after GOOD update (still v$baseline_ver)"
    local upg_state
    upg_state="$(awk -F= '/^state=/{sub(/^state=/,"");print;exit}' \
        /var/lib/airplanes-runtime-upgrade/upgrade-state 2>/dev/null || true)"
    [[ "$upg_state" == "INSTALLED" ]] \
        || fail "runtime-upgrade: GOOD update state=$upg_state, expected INSTALLED"
    # Consumer services restarted on the new release and healthy.
    assert_service_healthy readsb.service
    assert_service_healthy airplanes-feed.service
    assert_service_healthy airplanes-webconfig.service
    echo "image-probe: GOOD convergence passed (current=v$_runtime_good_version)"

    # --- BROKEN vN+1 : expect rollback to the GOOD release ------------------
    echo "image-probe: driving runtime-self-update to BROKEN release"
    local pre_broken_ver="$_runtime_good_version"
    if _runtime_drive_update "$asset_base/broken"; then
        fail "runtime-upgrade: BROKEN update unexpectedly succeeded (rollback not triggered)"
    fi
    local post_broken_ver
    post_broken_ver="$(_runtime_current_version)"
    [[ "$post_broken_ver" == "$pre_broken_ver" ]] \
        || fail "runtime-upgrade: after BROKEN update current=v$post_broken_ver, expected rollback to v$pre_broken_ver"
    upg_state="$(awk -F= '/^state=/{sub(/^state=/,"");print;exit}' \
        /var/lib/airplanes-runtime-upgrade/upgrade-state 2>/dev/null || true)"
    [[ "$upg_state" == ROLLED_BACK_* ]] \
        || fail "runtime-upgrade: BROKEN update state=$upg_state, expected ROLLED_BACK_*"
    # Prior (good) release's services restored and healthy.
    assert_service_healthy readsb.service
    assert_service_healthy airplanes-feed.service
    assert_service_healthy airplanes-webconfig.service
    echo "image-probe: BROKEN rollback passed (current=v$post_broken_ver, state=$upg_state)"

    # Re-baseline feed's idempotency snapshot. The GOOD→BROKEN→rollback cycle
    # changed the managed-path symlink's target mtime: the GOOD install
    # extracted v9.9.99, the BROKEN install extracted v9.9.100, and the rollback
    # re-laid v9.9.99's managed paths. Even though the rollback returns to
    # v9.9.99, the re-lay creates new symlinks with fresh lstat() timestamps.
    # The feed harness's assert_binaries_unchanged compares this snapshot against
    # a fresh stat after the next run_feed_update; feed's update.sh takes the
    # version-match fast path and doesn't touch the binary, so feed-airplanes's
    # mtime must match. Snapshot here — at the final steady state just before
    # the persistence reboot — so the comparison is against the correct baseline.
    if [[ -f /var/lib/airplanes-boot-smoke/snapshot-mtimes ]]; then
        stat -c '%Y %n' \
            /usr/local/share/airplanes/feed-airplanes \
            /usr/local/share/airplanes/venv/bin/mlat-client \
            > /var/lib/airplanes-boot-smoke/snapshot-mtimes
        echo "image-probe: re-baselined feed idempotency snapshot after rollback"
    fi

    # Persist the expected post-reboot version + mark pass 1 done, then reboot
    # to verify the rolled-back release survives. The harness re-runs the
    # 'updated' phase (MAX_BOOT_ATTEMPTS=3), re-sourcing this probe.
    printf '%s' "$_runtime_good_version" > /var/lib/airplanes-boot-smoke/runtime-upgrade-good-version
    printf '%s' "rolled-back-rebooted" > "$progress"
    sync
    echo "image-probe: runtime-upgrade rebooting to verify rollback persistence"
    systemctl reboot
    # The reboot tears the VM down; the probe does not return past here on
    # pass 1. The harness boots again and re-enters at pass 2.
    sleep 120
    fail "runtime-upgrade: systemctl reboot did not take effect within 120s"
}

# On pass 2 the good version is read back from disk (a fresh process after the
# reboot has no in-memory _runtime_good_version).
if [[ -f /var/lib/airplanes-boot-smoke/runtime-upgrade-good-version ]]; then
    _runtime_good_version="$(cat /var/lib/airplanes-boot-smoke/runtime-upgrade-good-version)"
else
    _runtime_good_version=""
fi
_runtime_upgrade_probe

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

    # Boot recovery is now an IMAGE-OWNED shim (it must survive a fully
    # broken overlay), so the unit is a regular image file, not an overlay
    # symlink, and its ExecStart points at the image-owned shim.
    if [[ -L /etc/systemd/system/airplanes-runtime-update-recover.service \
            || ! -f /etc/systemd/system/airplanes-runtime-update-recover.service ]]; then
        fail "airplanes-runtime-update-recover.service should be an image-owned regular file, not an overlay symlink"
    fi
    [[ -x /usr/local/lib/airplanes-runtime/recover-shim ]] \
        || fail "recover-shim missing or not executable"
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

    # Decoder binaries' dynamic dependencies resolve on the target
    # image. If the runtime overlay was built against an Ubuntu library
    # set (or any environment whose SONAMEs diverge from Debian), `ldd`
    # surfaces the unresolved entries here. Capture the full output so
    # the failing library is visible in the harness log; bare
    # `ldd | grep` under `set -euo pipefail` can mask the real loader
    # error.
    for _decoder_bin in /usr/bin/readsb /usr/bin/airplanes-978 /usr/bin/dump978-fa; do
        [[ -e "$_decoder_bin" ]] || fail "decoder binary missing: $_decoder_bin"
        _ldd_out="$(ldd "$_decoder_bin" 2>&1)"
        _ldd_rc=$?
        if (( _ldd_rc != 0 )); then
            echo "image-probe: ldd $_decoder_bin exited $_ldd_rc" >&2
            echo "$_ldd_out" >&2
            fail "ldd failed for $_decoder_bin (rc=$_ldd_rc)"
        fi
        if grep -q 'not found' <<<"$_ldd_out"; then
            echo "image-probe: $_decoder_bin has unresolved shared libraries:" >&2
            grep 'not found' <<<"$_ldd_out" >&2
            fail "$_decoder_bin has unresolved shared libraries (likely ABI drift between build host and target image)"
        fi
    done

    # ExecStart targets that resolve into the overlay must be
    # executable on the running system. Stage-airplanes ships these as
    # symlinks into /opt/airplanes-runtime/current/, and the runtime
    # tarball is what owns the mode bits. A `0644` script behind an
    # ExecStart= line fails the unit at boot with `203/EXEC`, which is
    # how airplanes-runtime-update-recover.service broke on the first
    # flashed dev feeder. The release-build gate (exec-bit-check.sh)
    # is the primary defence; this is the runtime cross-check, scoped
    # to the recovery + self-update + decoder-wrapper paths boot-smoke
    # can reach without SDR hardware.
    for _exec_target in \
        /opt/airplanes-runtime/current/lib/runtime-self-update.sh \
        /opt/airplanes-runtime/current/lib/airplanes-update-orchestrator \
        /opt/airplanes-runtime/current/share/airplanes/readsb.sh \
        /opt/airplanes-runtime/current/share/airplanes/airplanes-978.sh \
        /opt/airplanes-runtime/current/share/airplanes/dump978-fa.sh \
        /opt/airplanes-runtime/current/share/airplanes/tar1090-uat-sync.sh \
        /opt/airplanes-runtime/current/lib/airplanes/render-status \
    ; do
        [[ -e "$_exec_target" ]] || fail "overlay file missing: $_exec_target"
        [[ -x "$_exec_target" ]] \
            || fail "overlay file not executable: $_exec_target (mode=$(stat -c '%a' -- "$_exec_target" 2>/dev/null || echo '???'))"
    done

    # Recovery service must not be failed. It runs as a `Type=oneshot`
    # gated on `ConditionPathExists=` for the recovery script — on a
    # fresh boot with no in-flight update state it should reach
    # inactive(dead) with Result=success. `failed` here means
    # ExecStart fired and exec()'d into something that failed (e.g.
    # the script is 0644, or has a CRLF shebang, or the kernel
    # rejected the interpreter line). readsb itself is intentionally
    # NOT asserted here: with no SDR in QEMU, readsb fails for
    # hardware-not-found reasons unrelated to packaging — the `ldd`
    # check above is the deterministic readsb-side assertion.
    _recover_active="$(systemctl show airplanes-runtime-update-recover.service \
        --property=ActiveState --value 2>/dev/null || true)"
    _recover_result="$(systemctl show airplanes-runtime-update-recover.service \
        --property=Result --value 2>/dev/null || true)"
    if [[ "$_recover_active" == "failed" || "$_recover_result" != "success" ]]; then
        # Inline a fragment of the unit's journal so the harness log
        # captures the actual exec failure, not just our diagnosis.
        echo "image-probe: airplanes-runtime-update-recover.service is in a bad state" >&2
        echo "  ActiveState=$_recover_active Result=$_recover_result" >&2
        systemctl status airplanes-runtime-update-recover.service --no-pager --full 2>&1 | head -40 >&2 || true
        fail "airplanes-runtime-update-recover.service ActiveState=$_recover_active Result=$_recover_result (expected dead/success)"
    fi

    # Every overlay-shipped unit's effective User=/Group=/SupplementaryGroups=
    # must resolve to an account that exists on the image. The chroot stage
    # creates the service accounts; a unit naming a principal the stage
    # forgot fails at boot with 217/USER (or a group setup error) BEFORE
    # ExecStart runs, and — being Restart=always — auto-restart-loops. That
    # state reads as `activating`, which neither `systemctl is-failed` nor
    # `systemctl --failed` flags, so it would otherwise sail through CI.
    # tar1090.service (User=tar1090) is the concrete case; this guards the
    # whole class. Read the EFFECTIVE values via `systemctl show` (after
    # drop-ins) rather than parsing the unit file. Note systemd reports
    # FragmentPath as the /etc/systemd/system symlink path, not the overlay
    # target, so we don't assert on its prefix — the explicit symlink-target
    # checks above already cover provenance. Skip units systemd doesn't load
    # (empty FragmentPath) and DynamicUser units (principal synthesised at
    # runtime).
    for _unit_file in /opt/airplanes-runtime/current/systemd/*.service; do
        [[ -e "$_unit_file" ]] || continue
        _unit="$(basename "$_unit_file")"
        _frag="$(systemctl show "$_unit" --property=FragmentPath --value 2>/dev/null || true)"
        [[ -n "$_frag" ]] || continue
        _dyn="$(systemctl show "$_unit" --property=DynamicUser --value 2>/dev/null || true)"
        [[ "$_dyn" == "yes" ]] && continue
        _u_user="$(systemctl show "$_unit" --property=User --value 2>/dev/null || true)"
        if [[ -n "$_u_user" ]]; then
            getent passwd "$_u_user" >/dev/null \
                || fail "overlay unit $_unit declares User=$_u_user but that account does not exist (would fail 217/USER at boot)"
        fi
        _u_group="$(systemctl show "$_unit" --property=Group --value 2>/dev/null || true)"
        if [[ -n "$_u_group" ]]; then
            getent group "$_u_group" >/dev/null \
                || fail "overlay unit $_unit declares Group=$_u_group but that group does not exist"
        fi
        # SupplementaryGroups is space-separated in `systemctl show` output.
        _u_supp="$(systemctl show "$_unit" --property=SupplementaryGroups --value 2>/dev/null || true)"
        # shellcheck disable=SC2086  # intentional split on space-separated group list
        for _g in $_u_supp; do
            getent group "$_g" >/dev/null \
                || fail "overlay unit $_unit lists SupplementaryGroups=$_g but that group does not exist"
        done
    done

    # Long-running overlay units must reach AND hold `active`. They are
    # Restart=always; a unit stuck in auto-restart (217/USER, 203/EXEC, a
    # bad config, a transient that exits cleanly then flaps) reports as
    # `activating`/`auto-restart`, which `is-failed`/`--failed` treat as
    # not-failed. Poll for `active`, then hold briefly and re-confirm so a
    # unit that blips active→dead is caught too. Neither needs an SDR:
    # tar1090 compresses whatever readsb writes (and loops when there is
    # nothing), graphs1090 renders from collectd. readsb stays excluded —
    # with no SDR in QEMU it legitimately does not reach active.
    for _svc in tar1090.service graphs1090.service; do
        _svc_deadline=$(( SECONDS + 75 ))
        while (( SECONDS < _svc_deadline )); do
            [[ "$(systemctl is-active "$_svc" 2>/dev/null || true)" == "active" ]] && break
            sleep 2
        done
        # Stability hold: a Type=simple unit can flash active then exit.
        sleep 3
        if [[ "$(systemctl is-active "$_svc" 2>/dev/null || true)" != "active" ]]; then
            echo "image-probe: $_svc did not reach/hold active" >&2
            systemctl show "$_svc" \
                --property=ActiveState,SubState,Result,ExecMainStatus,NRestarts 2>&1 \
                | sed 's/^/  /' >&2 || true
            systemctl status "$_svc" --no-pager --full 2>&1 | head -40 >&2 || true
            fail "$_svc not active (217=User= missing, 203=ExecStart not executable, exit-code=script error)"
        fi
    done
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

# Re-entrant: the runtime-overlay-upgrade-qemu variant reboots from inside this
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

rm -f "$sse_cookiejar"

echo "image-probe: passed"
