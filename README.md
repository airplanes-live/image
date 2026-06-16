<p align="center">
  <a href="https://airplanes.live"><img src=".github/assets/airplanes-live-logo.png" alt="airplanes.live" width="420"></a>
</p>

<p align="center">
  <a href="https://github.com/airplanes-live/image/actions/workflows/ci.yml"><img src="https://github.com/airplanes-live/image/actions/workflows/ci.yml/badge.svg?branch=dev" alt="CI"></a>
  <a href="https://github.com/airplanes-live/image/actions/workflows/build-image.yml"><img src="https://github.com/airplanes-live/image/actions/workflows/build-image.yml/badge.svg?branch=dev" alt="Build image"></a>
  <a href="https://github.com/airplanes-live/image/releases"><img src="https://img.shields.io/github/v/release/airplanes-live/image?include_prereleases&display_name=tag&label=release" alt="Latest release"></a>
  <a href="https://github.com/airplanes-live/image/releases"><img src="https://img.shields.io/github/downloads/airplanes-live/image/total?label=downloads" alt="Downloads"></a>
</p>

# airplanes.live feeder image

Raspberry Pi image for feeding ADS-B (1090 MHz) and optionally UAT (978 MHz) data to [airplanes.live](https://airplanes.live). Includes readsb (decoder), mlat-client, optional dump978-fa, tar1090 (live map), graphs1090 (stats), and a web UI for configuration.

## Install

You'll need a Raspberry Pi (Pi Zero 2 W or newer — 512 MB RAM minimum), an RTL-SDR dongle, a 1090 MHz antenna, and a microSD card (8 GB or larger).

Pick the latest **stable** release from the [Releases](https://github.com/airplanes-live/image/releases) page. A rolling [`dev-latest`](https://github.com/airplanes-live/image/releases/tag/dev-latest) pre-release also exists for testers — it's overwritten on every new dev build, so expect occasional breakage and be ready to reflash.

### Basic: flash and edit the boot config

Download the latest stable `.img.xz` from the [Releases](https://github.com/airplanes-live/image/releases) page. Flash it to the microSD card with any tool (`dd`, balenaEtcher, Win32 Disk Imager, etc.). **Before ejecting**, mount the FAT (boot) partition and edit `/boot/firmware/airplanes-config.txt`. The boot config is bootstrap-only — just enough to get the Pi on the network and reachable:

- `HOSTNAME` — set this if you run more than one Pi on your network (otherwise they'll all collide on `raspberrypi.local`). E.g. `HOSTNAME=airplanes-feeder` makes the Pi reachable at `airplanes-feeder.local`.
- `WIFI_SSID`, `WIFI_PASS`, `WIFI_COUNTRY` — only if you're not on Ethernet.
- `FEED_HOST` — leave commented out for production. Only set this if you're pointing at a non-production backend.
- `WEBSITE_URL` — leave commented out for production. Independent of `FEED_HOST`; points the feeder's claim / diagnostics / remote-config-sync POSTs at a non-production website.

Eject, insert into the Pi, connect SDR + antenna, power on. After ~2 minutes the feeder is online — browse to `http://<hostname>.local/` (or `http://raspberrypi.local/` if you didn't set `HOSTNAME`). **Set your receiver location (latitude / longitude / altitude) and MLAT display name in the web UI** — that's where they live now.

The boot config file is consumed on every boot: a successful apply renames it to `airplanes-config.applied.txt`. If anything fails (typo, unrecognized key, write error), the file stays in place and a sibling `airplanes-config.error.txt` explains what to fix. To re-prime later (e.g. fix a WiFi typo without booting), rename `airplanes-config.applied.txt` back to `airplanes-config.txt`, edit, and reboot.

### Alternative: Raspberry Pi Imager (if you want SSH set up at flash time)

[Raspberry Pi Imager](https://www.raspberrypi.com/software/) (v2.0.9 or newer) can configure hostname, WiFi, and SSH access during flashing — but only via a Custom Repository URL. The "Use Custom" local-image flow deliberately hides those settings.

1. On the [Releases](https://github.com/airplanes-live/image/releases) page, open the latest stable release and copy the URL of the `.rpi-imager-manifest.json` asset. (For testing the bleeding-edge build, use the manifest on the [`dev-latest`](https://github.com/airplanes-live/image/releases/tag/dev-latest) pre-release instead.)
2. In Imager, click the gear icon at the bottom of the OS list → **Custom Repository** → paste the URL.
3. Pick airplanes.live from the OS list, select your microSD card, click **Next**, then **Edit Settings** to configure hostname, WiFi, and SSH. Save and write.

The OS-list entry's name carries a `· <sha> · <HH:MM>Z` suffix on dev builds — compare it against the `dev-latest` release body to confirm Imager has fetched the current manifest (and is not flashing a cached earlier-today build).

Imager downloads and flashes the image for you. After first boot, browse to `http://<hostname>.local/` to set your receiver location and MLAT display name via the web UI.

### SSH access

The image ships with SSH enabled and a default login — username `pi`, password `airplanes` — so a fresh feeder is reachable over SSH with no extra setup (`ssh pi@<hostname>.local`). **Change it on first login** with `passwd`: the default is public and identical on every image, so anything that can reach the Pi on your network can log in until you change it. Setting your own username/password (or an SSH key) in Raspberry Pi Imager replaces the default.

### Already have a Pi feeding another aggregator?

You don't need to reflash. The [airplanes.live feed scripts](https://github.com/airplanes-live/feed) layer airplanes.live on top of an existing readsb setup (FlightAware, ADSBexchange, etc.).

### Coming from the legacy airplanes.live image?

There's no in-place upgrade from the [legacy image](https://github.com/airplanes-live/image-releases) to this one — base OS, web UI, and on-disk layout all differ. To run this image, reflash a microSD card following the steps above.

If you only need the current feeder scripts on your existing legacy install, you don't need to reflash. From the legacy web UI, click **Update Webconfig**, then **Update Feeder**. That gives you everything from [airplanes-live/feed](https://github.com/airplanes-live/feed) without disturbing the legacy web UI or base OS.

### Want a desktop GUI on the same Pi?

This image is a headless appliance — no graphical environment. If you also want the Raspberry Pi OS desktop on the same Pi, don't flash this image; flash standard Raspberry Pi OS Desktop and layer the feeder stack on top.

1. In [Raspberry Pi Imager](https://www.raspberrypi.com/software/), pick **Raspberry Pi OS (64-bit) with desktop** from the built-in OS list. Don't paste our Custom Repository URL here — that flashes the headless appliance.
2. Boot the Pi, then install (in this order — each step depends on the one before it):
   - [wiedehopf/readsb](https://github.com/wiedehopf/adsb-scripts/wiki/Automatic-installation-for-readsb) — the 1090 MHz decoder
   - [wiedehopf/tar1090](https://github.com/wiedehopf/tar1090) — live map (requires readsb)
   - [wiedehopf/graphs1090](https://github.com/wiedehopf/graphs1090) — performance graphs
   - [airplanes-live/feed](https://github.com/airplanes-live/feed) — connects the decoder to `feed.airplanes.live`
3. Configure receiver location, altitude, and MLAT display name by editing `/etc/airplanes/feed.env` directly. The appliance image's web admin UI is not part of this path.

Recommended on Pi 4 and Pi 5. Pi 3 / 3B+ are not recommended once you also run a browser — expect swapping. Don't pair the desktop with the feeder stack on a Pi Zero 2 W (512 MB RAM); use the headless image on Zero 2 W.

## Configuration

The web UI at `http://<hostname>.local/` is the recommended way to change settings after first boot:

- Receiver location, altitude, MLAT display name
- SDR gain
- UAT 978 MHz input (if you have a second SDR for UAT)

It writes `/etc/airplanes/feed.env` atomically and restarts services as needed. Command-line users can SSH in and edit `/etc/airplanes/feed.env` directly, then `sudo systemctl restart airplanes-feed.service` (and `airplanes-mlat.service` for MLAT changes).

### Forgot the web UI password?

The web UI password is set on your first visit and can't be recovered — but you can clear it and set a new one. There's no in-UI reset: you're locked out, so the trigger lives on the SD card instead.

Power off the Pi and remove the microSD card, then mount its FAT (boot) partition on another computer and create an empty file named `airplanes-reset-password` in `/boot/firmware/` (alongside `airplanes-config.txt`; make sure the name has no `.txt` or other extension). Reinsert the card and power on. On boot the feeder clears the stored password and deletes the marker, and the next visit to `http://<hostname>.local/` takes you back to the password-setup screen. Your feeder ID, location, and other settings are left untouched.

If you have SSH access you can skip pulling the card — `sudo touch /boot/firmware/airplanes-reset-password && sudo reboot` does the same thing.

---

Developer / homelab topics — pointing the feeder at a non-production backend, building from source — live in [README-advanced.md](README-advanced.md).
