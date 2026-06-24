#!/usr/bin/env bats

# Tests for stage-airplanes/06b-console-dashboard/00-run.sh. render-status, the
# ASCII assets, and the motd hook are delivered by the runtime overlay (laid by
# stage-airplanes/02-install-runtime-overlay under /opt/airplanes/current), so
# 06b installs ONLY the image-owned dashboard service unit and the getty@tty1
# override. It must not write anything under /usr/local or /etc/update-motd.d.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO_ROOT/stage-airplanes/06b-console-dashboard/00-run.sh"
    [[ -x "$SCRIPT" ]] || { echo "06b/00-run.sh missing/non-exec" >&2; return 1; }

    ROOTFS_DIR="$BATS_TEST_TMPDIR/rootfs"
    install -d -m 755 "$ROOTFS_DIR"
}

run_06b() {
    env \
        BASE_DIR="$REPO_ROOT" \
        ROOTFS_DIR="$ROOTFS_DIR" \
        bash -c "cd \"$REPO_ROOT/stage-airplanes/06b-console-dashboard\" && ./00-run.sh"
}

@test "06b installs the dashboard service unit and the getty override" {
    run run_06b
    [ "$status" -eq 0 ]
    [ -f "$ROOTFS_DIR/etc/systemd/system/airplanes-dashboard.service" ]
    [ -f "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d/override.conf" ]
}

@test "06b writes nothing under /usr/local or the motd hook (overlay-delivered)" {
    run run_06b
    [ "$status" -eq 0 ]
    # render-status + artwork are overlay-only now; 06b must not re-create the
    # old /usr/local fallback nor the image-owned motd hook.
    [ ! -e "$ROOTFS_DIR/usr/local/lib/airplanes/render-status" ]
    [ ! -e "$ROOTFS_DIR/usr/local/share/airplanes/logo.txt" ]
    [ ! -e "$ROOTFS_DIR/usr/local/share/airplanes/banner.txt" ]
    [ ! -e "$ROOTFS_DIR/usr/local/share/airplanes/banner-narrow.txt" ]
    [ ! -e "$ROOTFS_DIR/usr/local/share/airplanes/icon.txt" ]
    [ ! -e "$ROOTFS_DIR/etc/update-motd.d/10-airplanes-status" ]
}
