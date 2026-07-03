#!/bin/bash -e

# Ship the runtime-overlay release public key. The on-device installer
# (runtime-overlay/install.sh in runtime mode) verifies SHA256SUMS against
# this key before extracting any release artifact. Build-mode invocations
# from stage 02-install-runtime-overlay point at the same file inside the
# repo on the host so the verification path is identical in both modes.
install -D -m 0644 files/opt/airplanes/libexec/runtime-release.pub \
	"${ROOTFS_DIR}/opt/airplanes/libexec/runtime-release.pub"
