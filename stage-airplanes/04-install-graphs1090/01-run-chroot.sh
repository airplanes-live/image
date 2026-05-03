#!/bin/bash
# pi-gen invokes via `bash 01-run-chroot.sh` so shebang flags are ignored;
# explicit `set -e` is needed.
set -e

# graphs1090's install.sh calls `pkill -9 collectd`. pi-gen bind-mounts the
# host's /proc into the chroot, so without intercepting pkill we'd kill
# collectd processes outside our intended rootfs. PATH-prepended no-op stub
# scoped to this script's lifetime.
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/pkill <<'EOF'
#!/bin/bash
echo "pkill stub (chroot install): $*" >&2
exit 0
EOF
chmod +x /usr/local/sbin/pkill
trap 'rm -f /usr/local/sbin/pkill' EXIT

# systemctl-stub catches systemctl restart graphs1090/collectd/lighttpd; legitimate
# enable calls pass through.
export PATH="/usr/local/sbin:${PATH}"

cd /usr/share/graphs1090/git
bash install.sh test

# Wire 978 graph data source unconditionally. graphs1090's installer comments
# out URL_978 because /run/skyaware978 doesn't exist at build time. We point
# it at our 978-symlink dir; the inner symlink resolves to /run/airplanes-978.
sed -i -E 's|^[[:space:]]*#[[:space:]]*URL_978 .*|URL_978 "file:///usr/share/graphs1090/978-symlink"|' \
	/etc/collectd/collectd.conf
install -d -m 0755 /usr/share/graphs1090/978-symlink
ln -sfn /run/airplanes-978 /usr/share/graphs1090/978-symlink/data

# Normalize collectd Interface lines to canonical Pi names. graphs1090's
# installer scans /sys/class/net/ which is bind-mounted from the host during
# pi-gen build, so build-host interfaces (e.g., eno1, ens3) leak in. Replace
# the Interface "*" lines inside the <Plugin "interface"> block with the
# canonical Pi set.
awk '
/^<Plugin "interface">$/ { in_block=1; print; print "    Interface \"eth0\""; print "    Interface \"end0\""; print "    Interface \"wlan0\""; next }
in_block && /^<\/Plugin>/ { in_block=0; print; next }
in_block && /^[[:space:]]*Interface ".*"/ { next }
{ print }
' /etc/collectd/collectd.conf > /etc/collectd/collectd.conf.new
mv /etc/collectd/collectd.conf.new /etc/collectd/collectd.conf

# Drop graphs1090's :8542 alternative listener; we expose graphs1090 only via :80.
rm -f /etc/lighttpd/conf-enabled/95-graphs1090-otherport.conf
