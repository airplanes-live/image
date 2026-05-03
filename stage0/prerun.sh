#!/bin/bash -e

if [ "$RELEASE" != "trixie" ]; then
	echo "WARNING: RELEASE does not match the intended option for this branch."
	echo "         Please check the relevant README.md section."
fi

if [ "${ARCH}" = "armhf" ]; then
	BOOTSTRAP_URL="http://raspbian.raspberrypi.com/raspbian/"
else
	BOOTSTRAP_URL="http://deb.debian.org/debian/"
fi

if [ ! -d "${ROOTFS_DIR}" ]; then
	bootstrap ${RELEASE} "${ROOTFS_DIR}" "${BOOTSTRAP_URL}"
fi
