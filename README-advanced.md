# Advanced topics

## Pointing the feeder at a non-production backend

For end-to-end testing against a homelab or a cloned airplanes.live setup, edit `/boot/firmware/airplanes-config.txt` on the SD card and uncomment:

```
FEED_HOST=mybackend.local
```

This points both the mlat client and the readsb→aether beast forwarder at that host (mlat on port 31090, beast on 30004). Append `:PORT` to override the mlat port only — beast stays on 30004. For more involved setups (IPv6, non-default beast port, multi-host fan-out), set `MLATSERVER` and `TARGET` directly in the same file; explicit overrides win over `FEED_HOST`-derived defaults.

The boot config is applied on every boot and the file is then renamed to `airplanes-config.applied.txt`. To re-point at a different backend later, rename `airplanes-config.applied.txt` back to `airplanes-config.txt`, edit, and reboot. If the value fails validation, a sibling `airplanes-config.error.txt` will explain why and the original file stays in place for you to fix.

To verify on the booted Pi:

- `cat /etc/airplanes/feed.env` shows the resulting `MLATSERVER` and `TARGET`.
- `cat /proc/$(systemctl show -p MainPID --value airplanes-feed)/cmdline | tr '\0' ' '` includes `--net-connector mybackend.…`.
- `journalctl -u airplanes-mlat -b` shows `--server mybackend.…:31090`.

The aircraft data forwarder is `airplanes-feed.service`, not `readsb.service` (which is the local 1090 MHz decoder).

## Building the image

The build system is the upstream [RPI-Distro/pi-gen](https://github.com/RPI-Distro/pi-gen); refer there for `build.sh`, `STAGE_LIST`, `IMG_NAME`, and other framework semantics not specific to this fork. The fork-specific stages live under `stage-airplanes/`, and channel selection (`config-dev` vs `config-stable`) determines whether software dependencies track upstream branches or pinned SHAs.
