#!/bin/bash -e

# graphs1090's install.sh copies files OUT of git/ into the parent dir at
# install time; the source dir is unused at runtime.
rm -rf "${ROOTFS_DIR}/usr/share/graphs1090/git"
