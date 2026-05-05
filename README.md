# airplanes.live feeder image

Raspberry Pi image for feeding ADS-B (1090 MHz) and optionally UAT (978 MHz) data to [airplanes.live](https://airplanes.live). Bundles readsb (decoder), mlat-client (multilateration), optional dump978-fa, the tar1090 live map, graphs1090 stats, and a small web UI for ongoing configuration.

## Install

You'll need a Raspberry Pi (any model with WiFi or Ethernet and 1 GB+ RAM), an RTL-SDR dongle, a 1090 MHz antenna, and a microSD card (8 GB or larger). Download the latest image from the [Releases](https://github.com/airplanes-live/image/releases) page (`.img.xz`).

### Path 1: Raspberry Pi Imager (recommended)

[Raspberry Pi Imager](https://www.raspberrypi.com/software/) handles flashing plus initial setup (hostname, WiFi, SSH). Use **version 2.0.9 or newer** — earlier versions had a bug where the SSH-enable option wrote your public key but didn't start the SSH service, leaving SSH refused on first boot. The fix landed upstream in commit `2c428de4` ([raspberrypi/rpi-imager](https://github.com/raspberrypi/rpi-imager)).

1. Open Raspberry Pi Imager.
2. **Choose OS** → **Use custom**, then select the `.img.xz` you downloaded.
3. **Choose Storage** → pick your microSD card.
4. Click **Next**. When prompted to apply OS customisation settings, click **Edit Settings** and configure:
   - **Hostname** — e.g. `airplanes-feeder` (you'll reach the Pi as `<hostname>.local` on your network).
   - **WiFi** — set SSID, password, and country code (skip if you're using Ethernet).
   - **SSH** — enable if you want remote access; pick password or public-key auth.
5. Save the settings and write the image.

Eject the card, insert it into the Pi, connect the SDR and antenna, and power on. The feeder takes a couple of minutes on first boot before it starts sending data. Then browse to `http://<hostname>.local/` to set your receiver location and MLAT display name.

### Path 2: Direct flash, configure via the web UI

If you're not using Raspberry Pi Imager, the simplest path is: flash with any tool, plug in via Ethernet, configure everything through the web UI on first boot.

1. Decompress the `.img.xz`.
2. Flash the resulting `.img` to the microSD card (`dd`, balenaEtcher, Win32 Disk Imager, etc).
3. Eject the card, insert it into the Pi, connect SDR + antenna + Ethernet, power on.
4. After ~2 minutes the feeder is online. Browse to `http://raspberrypi.local/` to set your receiver location, MLAT display name, and other settings.

If you can't use Ethernet, mount the FAT (boot) partition of the SD card before ejecting and set `WIFI_SSID`, `WIFI_PASS`, `WIFI_COUNTRY` in `/boot/firmware/airplanes-config.txt`. The same file lets you pre-set receiver location, MLAT display name, and a handful of other options at first boot if you'd rather skip the web UI step — see the inline comments in the file for the full list. The file is read **once** on first boot; later edits don't apply (use the web UI for ongoing changes).

## Configuration

After first boot, the web UI at `http://<hostname>.local/` is the recommended way to change settings:

- Receiver location, altitude, MLAT display name
- SDR gain
- UAT 978 MHz input (if you have a second SDR for UAT)

The web UI writes to `/etc/airplanes/feed.env` atomically and restarts the relevant services for you.

If you'd rather work from the command line, SSH in and edit `/etc/airplanes/feed.env` directly, then run `sudo systemctl restart airplanes-feed.service` (and `airplanes-mlat.service` for MLAT changes). Most users won't need to.

---

## For developers

### Pointing the feeder at a non-production backend

For end-to-end testing against a homelab or a cloned airplanes.live setup, edit `/boot/firmware/airplanes-config.txt` on the SD card before first boot and uncomment:

```
FEED_HOST=mybackend.local
```

This points both the mlat client and the readsb→aether beast forwarder at that host (mlat on port 31090, beast on 30004). Append `:PORT` to override the mlat port only — beast stays on 30004. For more involved setups (IPv6, non-default beast port, multi-host fan-out), set `MLATSERVER` and `TARGET` directly in the same file; explicit overrides win over `FEED_HOST`-derived defaults.

To verify on the booted Pi:

- `cat /etc/airplanes/feed.env` shows the resulting `MLATSERVER` and `TARGET`.
- `cat /proc/$(systemctl show -p MainPID --value airplanes-feed)/cmdline | tr '\0' ' '` includes `--net-connector mybackend.…`.
- `journalctl -u airplanes-mlat -b` shows `--server mybackend.…:31090`.

The aircraft data forwarder is `airplanes-feed.service`, not `readsb.service` (which is the local 1090 MHz decoder).

### Building the image

The build system is the upstream [RPI-Distro/pi-gen](https://github.com/RPI-Distro/pi-gen); refer there for `build.sh`, `STAGE_LIST`, `IMG_NAME`, and other framework semantics not specific to this fork. The fork-specific stages live under `stage-airplanes/`, and channel selection (`config-dev` vs `config-stable`) determines whether software dependencies track upstream branches or pinned SHAs.
