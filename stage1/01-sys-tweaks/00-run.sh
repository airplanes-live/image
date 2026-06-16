#!/bin/bash -e

install -v -m 644 files/fstab "${ROOTFS_DIR}/etc/fstab"

on_chroot << EOF
if ! id -u ${FIRST_USER_NAME} >/dev/null 2>&1; then
	adduser --disabled-login --gecos "" ${FIRST_USER_NAME}
fi

if [ -n "${FIRST_USER_PASS}" ]; then
	echo "${FIRST_USER_NAME}:${FIRST_USER_PASS}" | chpasswd
fi
# adduser --disabled-login leaves the shell at /usr/sbin/nologin on this image.
# The first user is the operator account that rpi-imager, the webconfig SSH
# controls, and airplanes-config.txt (SSH_PASSWORD/SSH_PUBKEY) can each enable
# for login, so it needs a real shell regardless of FIRST_USER_PASS. It still
# ships --disabled-login (locked, keyless), so the shell stays unreachable until
# an enable path adds a credential.
usermod -s /bin/bash "${FIRST_USER_NAME}"
echo "root:root" | chpasswd
EOF
