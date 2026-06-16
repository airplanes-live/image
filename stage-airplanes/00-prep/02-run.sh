#!/bin/bash -e

# Drop a sshd_config.d/*.conf snippet that pins password-capable auth off in
# the shipped image. Lexical order means cloud-init's 50-cloud-init.conf
# (written when rpi-imager emits ssh_pwauth) wins over our 90-airplanes.conf
# for first-match directives, so explicit user opt-in still produces working
# password SSH. With no customization the snippet is the active value: sshd
# is reachable but unauthenticatable (no creds anywhere).
#
# Lifted out of upstream's PUBKEY_ONLY_SSH path because that flag's contract
# is "ship a key-only image with a baked key" and gates on
# PUBKEY_SSH_FIRST_USER — we don't bake keys; rpi-imager / cloud-init injects
# them at first boot.

sshd_config="${ROOTFS_DIR}/etc/ssh/sshd_config"

if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' "$sshd_config"; then
	echo "ERROR: $sshd_config does not Include /etc/ssh/sshd_config.d/*.conf — refusing to ship a bypassable SSH posture" >&2
	exit 1
fi

install -d -m 755 "${ROOTFS_DIR}/etc/ssh/sshd_config.d"
cat > "${ROOTFS_DIR}/etc/ssh/sshd_config.d/90-airplanes.conf" <<'EOF'
# Airplanes feeder image default SSH posture. cloud-init writes
# 50-cloud-init.conf for ssh_pwauth opt-in, which wins lexical order.
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
# Keep the stock per-user ~/.ssh/authorized_keys (so rpi-imager-injected keys
# still authenticate) AND add a managed drop-in directory. The per-device SSH
# opt-in (boot config / webconfig) writes the pi account's key to
# /etc/ssh/authorized_keys.d/pi.
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%u
EOF
chmod 0644 "${ROOTFS_DIR}/etc/ssh/sshd_config.d/90-airplanes.conf"

# Managed authorized_keys directory for the per-device SSH opt-in. The pi
# account's key lands here as /etc/ssh/authorized_keys.d/pi (written by
# airplanes-first-run from the boot config, or by webconfig's apl-ssh helper).
install -d -m 755 "${ROOTFS_DIR}/etc/ssh/authorized_keys.d"
