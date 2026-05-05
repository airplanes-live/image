<p align="center">
  <a href="https://airplanes.live"><img src=".github/assets/airplanes-live-logo.png" alt="airplanes.live" width="420"></a>
</p>

<p align="center">
  <a href="https://github.com/airplanes-live/image/actions/workflows/ci.yml"><img src="https://github.com/airplanes-live/image/actions/workflows/ci.yml/badge.svg?branch=dev" alt="CI"></a>
  <a href="https://github.com/airplanes-live/image/actions/workflows/build-image.yml"><img src="https://github.com/airplanes-live/image/actions/workflows/build-image.yml/badge.svg?branch=dev" alt="Build image"></a>
  <a href="https://github.com/airplanes-live/image/releases"><img src="https://img.shields.io/github/v/release/airplanes-live/image?include_prereleases&display_name=tag&label=release" alt="Latest release"></a>
</p>

# airplanes.live feeder image

Raspberry Pi image for feeding ADS-B (1090 MHz) and optionally UAT (978 MHz) data to [airplanes.live](https://airplanes.live). Includes readsb (decoder), mlat-client, optional dump978-fa, tar1090 (live map), graphs1090 (stats), and a web UI for configuration.

## Install

You'll need a Raspberry Pi (Pi Zero 2 W or newer — 512 MB RAM minimum), an RTL-SDR dongle, a 1090 MHz antenna, and a microSD card (8 GB or larger). Download the latest `.img.xz` from the [Releases](https://github.com/airplanes-live/image/releases) page.

### Basic: flash and edit the boot config

Flash the image to the microSD card with any tool (`dd`, balenaEtcher, Win32 Disk Imager, etc.). **Before ejecting**, mount the FAT (boot) partition and edit `/boot/firmware/airplanes-config.txt`:

- `LATITUDE`, `LONGITUDE`, `ALTITUDE` — your receiver's location (decimal degrees, WGS84). MLAT requires accurate values.
- `USER` — your MLAT display name (shows up on airplanes.live).
- `HOSTNAME` — set this if you run more than one Pi on your network (otherwise they'll all collide on `raspberrypi.local`). E.g. `HOSTNAME=airplanes-feeder` makes the Pi reachable at `airplanes-feeder.local`.
- `WIFI_SSID`, `WIFI_PASS`, `WIFI_COUNTRY` — only if you're not on Ethernet.

Eject, insert into the Pi, connect SDR + antenna, power on. After ~2 minutes the feeder is online — browse to `http://<hostname>.local/` (or `http://raspberrypi.local/` if you didn't set `HOSTNAME`) to verify and tweak via the web UI.

The boot config file is read **once** on first boot; later edits don't apply (use the web UI for ongoing changes).

### Alternative: Raspberry Pi Imager (if you want SSH set up at flash time)

[Raspberry Pi Imager](https://www.raspberrypi.com/software/) (v2.0.9 or newer) can configure hostname, WiFi, and SSH access during flashing — but only via a Custom Repository URL. The "Use Custom" local-image flow deliberately hides those settings.

1. On the [Releases](https://github.com/airplanes-live/image/releases) page, copy the URL of the `.rpi-imager-manifest.json` asset attached to the release you want.
2. In Imager, click the gear icon at the bottom of the OS list → **Custom Repository** → paste the URL.
3. Pick airplanes.live from the OS list, select your microSD card, click **Next**, then **Edit Settings** to configure hostname, WiFi, and SSH. Save and write.

Imager downloads and flashes the image for you. After first boot, browse to `http://<hostname>.local/` to set your receiver location and MLAT display name via the web UI.

### Already have a Pi feeding another aggregator?

You don't need to reflash. The [airplanes.live feed scripts](https://github.com/airplanes-live/feed) layer airplanes.live on top of an existing readsb setup (FlightAware, ADSBexchange, etc.).

## Configuration

The web UI at `http://<hostname>.local/` is the recommended way to change settings after first boot:

- Receiver location, altitude, MLAT display name
- SDR gain
- UAT 978 MHz input (if you have a second SDR for UAT)

It writes `/etc/airplanes/feed.env` atomically and restarts services as needed. Command-line users can SSH in and edit `/etc/airplanes/feed.env` directly, then `sudo systemctl restart airplanes-feed.service` (and `airplanes-mlat.service` for MLAT changes).

---

Developer / homelab topics — pointing the feeder at a non-production backend, building from source — live in [README-advanced.md](README-advanced.md).
