#!/usr/bin/env bats

# Tests for stage-airplanes/06b-console-dashboard/00-run.sh's idempotent
# install of render-status + ASCII assets + motd hook. The block installs
# image-side UNLESS the runtime-overlay path already placed the files (via
# stage-airplanes/02-install-runtime-overlay running ahead of 06b). The
# dashboard service unit and getty@tty1 override stay unconditional.

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

@test "render-status absent: 06b installs the image-owned fallback" {
    run run_06b
    [ "$status" -eq 0 ]
    [ -x "$ROOTFS_DIR/usr/local/lib/airplanes/render-status" ]
    [ -f "$ROOTFS_DIR/usr/local/share/airplanes/logo.txt" ]
    [ -f "$ROOTFS_DIR/usr/local/share/airplanes/banner.txt" ]
    [ -f "$ROOTFS_DIR/usr/local/share/airplanes/banner-narrow.txt" ]
    [ -f "$ROOTFS_DIR/usr/local/share/airplanes/icon.txt" ]
    [ -x "$ROOTFS_DIR/etc/update-motd.d/10-airplanes-status" ]

    # Dashboard service + getty override are always image-owned.
    [ -f "$ROOTFS_DIR/etc/systemd/system/airplanes-dashboard.service" ]
    [ -f "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d/override.conf" ]
}

@test "render-status already symlinked into runtime overlay: 06b skips it" {
    # Simulate 02-install-runtime-overlay having run ahead of 06b.
    install -d -m 755 "$ROOTFS_DIR/usr/local/lib/airplanes"
    install -d -m 755 "$ROOTFS_DIR/opt/airplanes-runtime/current/lib/airplanes"
    : > "$ROOTFS_DIR/opt/airplanes-runtime/current/lib/airplanes/render-status"
    chmod 0755 "$ROOTFS_DIR/opt/airplanes-runtime/current/lib/airplanes/render-status"
    ln -sf /opt/airplanes-runtime/current/lib/airplanes/render-status \
        "$ROOTFS_DIR/usr/local/lib/airplanes/render-status"

    run run_06b
    [ "$status" -eq 0 ]

    # 06b should NOT have replaced the symlink with a regular file.
    [ -L "$ROOTFS_DIR/usr/local/lib/airplanes/render-status" ]
    [ "$(readlink "$ROOTFS_DIR/usr/local/lib/airplanes/render-status")" \
      = "/opt/airplanes-runtime/current/lib/airplanes/render-status" ]

    # 06b should NOT have installed the image-owned ASCII assets either.
    [ ! -e "$ROOTFS_DIR/usr/local/share/airplanes/logo.txt" ]
    [ ! -e "$ROOTFS_DIR/etc/update-motd.d/10-airplanes-status" ]

    # Dashboard service + getty override still land unconditionally.
    [ -f "$ROOTFS_DIR/etc/systemd/system/airplanes-dashboard.service" ]
    [ -f "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d/override.conf" ]
}

@test "render-status as plain file already present: 06b leaves it alone" {
    # Defensive case: prior stage (not the overlay) put a real file there.
    install -d -m 755 "$ROOTFS_DIR/usr/local/lib/airplanes"
    printf '#!/bin/bash\necho prior\n' > "$ROOTFS_DIR/usr/local/lib/airplanes/render-status"
    chmod 0755 "$ROOTFS_DIR/usr/local/lib/airplanes/render-status"
    prior_sha=$(sha256sum "$ROOTFS_DIR/usr/local/lib/airplanes/render-status" | cut -d' ' -f1)

    run run_06b
    [ "$status" -eq 0 ]

    new_sha=$(sha256sum "$ROOTFS_DIR/usr/local/lib/airplanes/render-status" | cut -d' ' -f1)
    [ "$prior_sha" = "$new_sha" ]
}
