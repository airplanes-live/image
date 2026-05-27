#!/bin/bash -e

# Boot-noise cleanup. Two unrelated tweaks bundled because both are
# small "shipped image emits a warning that has no operator action"
# fixes:
#
# 1. Override lighttpd-mod-openssl's modules-load.d snippet. The package
#    ships /usr/lib/modules-load.d/lighttpd-mod-openssl.conf with the
#    single line `tls`, which asks systemd-modules-load to load the
#    kernel TLS offload module. RPi kernels don't build that module, so
#    every boot logs `Failed to find module 'tls'`. lighttpd's TLS runs
#    in userspace via OpenSSL; the kernel module is not needed.
#    Same-filename override at /etc/modules-load.d/ masks the /usr file.
install -D -m 0644 files/etc/modules-load.d/lighttpd-mod-openssl.conf \
	"${ROOTFS_DIR}/etc/modules-load.d/lighttpd-mod-openssl.conf"

# 2. Tighten /lib/netplan/00-network-manager-all.yaml perms. The file
#    ships from the Debian/pi-gen base rootfs at mode 0644 and is not
#    tracked by dpkg, so package upgrades won't reset perms. netplan's
#    generator warns "Permissions for ... are too open. Netplan
#    configuration should NOT be accessible by others." on every
#    network event (4× per boot in practice). Mode 0600 silences the
#    warning without changing behavior — only root reads the file.
NETPLAN_YAML="${ROOTFS_DIR}/lib/netplan/00-network-manager-all.yaml"
if [[ -e "$NETPLAN_YAML" ]]; then
	chmod 0600 "$NETPLAN_YAML"
else
	echo "WARNING: $NETPLAN_YAML missing — netplan perm fix skipped" >&2
fi
