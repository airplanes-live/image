#!/usr/bin/env bats

# Tests for stage-airplanes/06b-console-dashboard/00-run.sh gating the
# render-status + ASCII assets + motd hook installs on
# AIRPLANES_USE_LEGACY_DECODER_STAGES. The dashboard service unit and the
# getty@tty1 override stay unconditional regardless of the flag.

bats_require_minimum_version 1.5.0

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO_ROOT/stage-airplanes/06b-console-dashboard/00-run.sh"
    [[ -x "$SCRIPT" ]] || { echo "06b/00-run.sh missing/non-exec" >&2; return 1; }

    ROOTFS_DIR="$BATS_TEST_TMPDIR/rootfs"
    install -d -m 755 "$ROOTFS_DIR"
}

run_06b() {
    # 06b's 00-run.sh runs in stage-airplanes/06b-console-dashboard/ via
    # pi-gen's `(cd "$STAGE_DIR" && ./00-run.sh)` pattern.
    env \
        BASE_DIR="$REPO_ROOT" \
        ROOTFS_DIR="$ROOTFS_DIR" \
        AIRPLANES_USE_LEGACY_DECODER_STAGES="$1" \
        bash -c "cd \"$REPO_ROOT/stage-airplanes/06b-console-dashboard\" && ./00-run.sh"
}

@test "flag=0 (overlay path): render-status + assets + motd hook NOT installed image-side" {
    run run_06b 0
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS_DIR/usr/local/lib/airplanes/render-status" ]
    [ ! -e "$ROOTFS_DIR/usr/local/share/airplanes/logo.txt" ]
    [ ! -e "$ROOTFS_DIR/usr/local/share/airplanes/banner.txt" ]
    [ ! -e "$ROOTFS_DIR/usr/local/share/airplanes/banner-narrow.txt" ]
    [ ! -e "$ROOTFS_DIR/usr/local/share/airplanes/icon.txt" ]
    [ ! -e "$ROOTFS_DIR/etc/update-motd.d/10-airplanes-status" ]

    # Dashboard service + getty override are always image-owned.
    [ -f "$ROOTFS_DIR/etc/systemd/system/airplanes-dashboard.service" ]
    [ -f "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d/override.conf" ]
}

@test "flag=1 (legacy path): render-status + assets + motd hook are installed" {
    run run_06b 1
    [ "$status" -eq 0 ]
    [ -x "$ROOTFS_DIR/usr/local/lib/airplanes/render-status" ]
    [ -f "$ROOTFS_DIR/usr/local/share/airplanes/logo.txt" ]
    [ -f "$ROOTFS_DIR/usr/local/share/airplanes/banner.txt" ]
    [ -f "$ROOTFS_DIR/usr/local/share/airplanes/banner-narrow.txt" ]
    [ -f "$ROOTFS_DIR/usr/local/share/airplanes/icon.txt" ]
    [ -x "$ROOTFS_DIR/etc/update-motd.d/10-airplanes-status" ]

    [ -f "$ROOTFS_DIR/etc/systemd/system/airplanes-dashboard.service" ]
    [ -f "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d/override.conf" ]
}

@test "unset flag defaults to overlay (=0)" {
    run env \
        BASE_DIR="$REPO_ROOT" \
        ROOTFS_DIR="$ROOTFS_DIR" \
        bash -c "cd \"$REPO_ROOT/stage-airplanes/06b-console-dashboard\" && ./00-run.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOTFS_DIR/usr/local/lib/airplanes/render-status" ]
    [ -f "$ROOTFS_DIR/etc/systemd/system/airplanes-dashboard.service" ]
}
