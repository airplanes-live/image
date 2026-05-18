# Advanced topics

## Pointing the feeder at a non-production backend

For end-to-end testing against a homelab or a cloned airplanes.live setup, edit `/boot/firmware/airplanes-config.txt` on the SD card and uncomment:

```
FEED_HOST=feed.airplanes.test
WEBSITE_URL=http://airplanes.test/
```

`FEED_HOST` points the mlat client and the readsb→aether beast forwarder at that host (mlat on port 31090, beast on 30004). Append `:PORT` to override the mlat port only — beast stays on 30004. Advanced topologies (bracketed IPv6, non-default beast port, multi-host fan-out) are not expressible from the SD card — SSH in after first boot and edit `/etc/airplanes/feed.env` directly, then `sudo systemctl restart airplanes-feed.service airplanes-mlat.service`.

`WEBSITE_URL` is independent — it points the feeder's website-side POSTs (claim, diagnostics, remote-config-sync) at a non-production website. Full URL with scheme, optional port and path. For a full homelab redirect you generally want both keys set; they target different services.

The boot config is applied on every boot and the file is then renamed to `airplanes-config.applied.txt`. To re-point at a different backend later, rename `airplanes-config.applied.txt` back to `airplanes-config.txt`, edit, and reboot. If the value fails validation, a sibling `airplanes-config.error.txt` will explain why and the original file stays in place for you to fix.

The boot-config Wi-Fi keys (`WIFI_SSID` / `WIFI_PASS` / `WIFI_COUNTRY`) are bootstrap-only. After first boot, manage Wi-Fi networks from the webconfig UI — add, edit, remove, and optionally test-connect before saving. Adding or removing networks via the UI does **not** write back to `airplanes-config.txt`; the boot config is consumed once and the runtime state lives entirely in NetworkManager's `/etc/NetworkManager/system-connections/` directory.

To verify on the booted Pi:

- `cat /etc/airplanes/feed.env` shows the resulting `MLATSERVER`, `TARGET`, and `APL_FEED_WEBSITE_URL`.
- `cat /proc/$(systemctl show -p MainPID --value airplanes-feed)/cmdline | tr '\0' ' '` includes `--net-connector feed.airplanes.test,30004,…`.
- `journalctl -u airplanes-mlat -b` shows `--server feed.airplanes.test:31090`.
- `journalctl -u airplanes-diagnostics -b` shows the POST URL using the `APL_FEED_WEBSITE_URL` value.

The aircraft data forwarder is `airplanes-feed.service`, not `readsb.service` (which is the local 1090 MHz decoder).

## Building the image

The build system is the upstream [RPI-Distro/pi-gen](https://github.com/RPI-Distro/pi-gen); refer there for `build.sh`, `STAGE_LIST`, `IMG_NAME`, and other framework semantics not specific to this fork. The fork-specific stages live under `stage-airplanes/`, and channel selection (`config-dev` vs `config-stable`) determines whether software dependencies track upstream branches or pinned SHAs.
