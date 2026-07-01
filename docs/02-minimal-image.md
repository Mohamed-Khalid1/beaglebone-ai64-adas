# 02 — Minimal image (`bbai64-minimal-image`, brand = `core`)

A custom, graphics-free Yocto image: **console + SSH + Python3 + hardware bring-up
tools**, no Weston/Qt, no EdgeAI stack. Built as the fast, low-risk foundation for
proving boot, networking, and C7x enablement before moving to the full EdgeAI image.

## What it contains
- systemd, dropbear SSH, Python3, `i2c-tools`, `devmem2`
- USB-C network gadget (see below)
- **No** graphics: `wayland opengl x11 vulkan opencl` all stripped for the `core` brand

Recipe: [`yocto/meta-bbai64/recipes-core/images/bbai64-minimal-image.bb`](../yocto/meta-bbai64/recipes-core/images/bbai64-minimal-image.bb)

## Build
```bash
cd tisdk
source sources/oe-core/oe-init-build-env build
# ensure ARAGO_BRAND = "core" in conf/local.conf
bitbake bbai64-minimal-image
```
Output: `build/deploy-ti/images/beaglebone-ai64/bbai64-minimal-image-*.wic.xz` (~105 MB).

## Flash
```bash
scripts/flash.sh /dev/sdX        # identify the device with lsblk FIRST
```

---

## Complications hit & how they were solved

### 1. "Dead" board — missing `sysfw.itb` (split boot)
**Symptom:** flashed SD boots to power-LED only, no activity, board appears dead.
**Root cause:** the J721E uses **split boot** — the R5 SPL inside `tiboot3.bin` loads
the system firmware from a file named **exactly** `sysfw.itb` in the FAT boot
partition. `j721e.inc`'s bare `sysfw.itb` entry can be *absent* at `.wic` build time
(`do_image_wic: cannot stat …`), producing an unbootable card that stalls before any LED.
**Fix (in `local.conf`):** copy the always-present board firmware **as** `sysfw.itb`:
```
IMAGE_BOOT_FILES:remove = "sysfw.itb"
IMAGE_BOOT_FILES:append = " sysfw-j721e-gp-evm.itb;sysfw.itb"
```
Full write-up: [`raw-logs/BBAI64_MINIMAL_IMAGE_NOTES.md`](raw-logs/BBAI64_MINIMAL_IMAGE_NOTES.md).

### 2. No onboard USB-serial
The BBAI-64 has **no onboard USB-serial** — `/dev/ttyUSB*` never appears without an
external 3.3 V USB-TTL adapter. This is **not a fault**. We connect over the USB-C
**network gadget** instead (see below), or IPv6 link-local as a rescue path.

### 3. USB-C networking that survives reboots
The stock `g_ether` gadget **randomizes its MAC every boot**, so the host interface
name (`enxXXXXXXXXXXXX`) changes on every plug — nothing could be hardcoded.
**Fixes, implemented in the [`usb-gadget-net`](../yocto/meta-bbai64/recipes-connectivity/usb-gadget-net/) recipe:**
- **Pin the MACs** via `/etc/modprobe.d/g_ether.conf`
  (`dev_addr=aa:bb:cc:00:00:02 host_addr=aa:bb:cc:00:00:01`) → the host iface is now a
  stable `enxaabbcc000001`.
- Assign `192.168.7.2` from a **systemd device-bound oneshot service**
  (`usb0-static-ip.service`), replacing an unreliable udev `RUN+=` rule.
- Blacklist `usb0` in connman so it stops flushing the address.

Host-side connection needs four things (IP on `192.168.7.0/24`, a connected route out
the gadget iface, `rp_filter` not strict, NetworkManager kept off the iface); the
helper scripts handle all four — see [`scripts/`](../scripts/) and
[`raw-logs/BOARD_LOGIN_GUIDE.md`](raw-logs/BOARD_LOGIN_GUIDE.md).

### 4. Disk-tight host
A clean build needs 80–120 GB; the host had ~15 GB free. `INHERIT += "rm_work"` and a
shared ~13 GB sstate cache are **mandatory** — do not disable them.

## Board facts
- Login: user **`root`**, **empty password** (`debug-tweaks`).
- Hostname `beaglebone-ai64`; dropbear SSH.
- USB-C gadget: board `usb0` = `192.168.7.2`, host gadget iface = `192.168.7.1`.
- `lsusb` showing `0525:a4a2` = the board booted fine.
