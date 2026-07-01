# BeagleBone AI-64 — Minimal Yocto Image: Build & Bring-Up Notes

**Board:** BeagleBone AI-64 (Texas Instruments TDA4VM / J721E, dual Cortex-A72)
**Storage / boot media:** Lexar Blue Plus 64 GB microSD
**Build system:** TI Processor SDK (Yocto **Scarthgap 5.0 LTS**, `arago` distro)
**Date of bring-up:** 2026-06-12
**Status:** ✅ Image builds, boots, and is reachable over SSH

---

## 1. Purpose of this document

This file records **what was built**, **every problem hit during bring-up**, and **the
root cause + fix for each**, so the next phases (adding drivers, applications, peripherals,
production hardening) don't repeat the same dead ends. The headline lesson:

> **The board booted our image correctly on the very first try. Every single
> "failure" we chased was a host-side networking/config misunderstanding — not a
> board, kernel, or image-build problem.** Diagnose from the serial/USB link
> evidence, not from assumptions carried over from the stock Debian image.

---

## 2. Build environment layout

| Item | Path |
|---|---|
| TISDK / Yocto root | `/home/mohamedkhalid/tisdk/` |
| Build directory | `/home/mohamedkhalid/tisdk/build/` |
| Layer sources | `/home/mohamedkhalid/tisdk/sources/` |
| Deploy (boot + rootfs artifacts) | `/home/mohamedkhalid/tisdk/build/deploy-ti/images/beaglebone-ai64/` |
| sstate cache (shared, ~13 GB) | `/home/mohamedkhalid/yocto-bbai64/sstate-cache/` |
| Downloads | `/home/mohamedkhalid/yocto-bbai64/build/downloads/` |
| Flash helper script | `/home/mohamedkhalid/minimal_image/flash.sh` |
| Connect helper script | `/home/mohamedkhalid/minimal_image/connect-bbai64.sh` |
| These notes | `/home/mohamedkhalid/minimal_image/BBAI64_MINIMAL_IMAGE_NOTES.md` |

**Host disk caution:** `/dev/sda5` had only ~15 GB free during this work. `rm_work` is
enabled in `local.conf` for this reason — do **not** disable it without freeing space first.
A clean (non-cached) Scarthgap build needs 80–120 GB; we rely heavily on the populated
sstate cache instead.

---

## 3. What was created — the `meta-bbai64-minimal` layer

A dedicated layer at `/home/mohamedkhalid/tisdk/sources/meta-bbai64-minimal/`, with
**BBFILE_PRIORITY 14** (deliberately above `meta-edgeai` = 13) so our bbappends win.

```
meta-bbai64-minimal/
├── conf/layer.conf
├── recipes-core/images/
│   └── bbai64-minimal-image.bb            # the target image recipe
├── recipes-connectivity/usb-gadget-net/
│   ├── usb-gadget-net.bb                  # USB-C network gadget (g_ether) recipe
│   └── files/
│       ├── g_ether-load.conf              # /etc/modules-load.d/g_ether.conf → load at boot
│       ├── g_ether-options.conf           # /etc/modprobe.d/g_ether.conf → PIN the MACs
│       └── usb0-static-ip.service         # systemd oneshot → assigns 192.168.7.2 to usb0
│       # (the old fragile 72-usb-gadget.rules udev rule was REMOVED — see Problem #5)
└── recipes-tisdk/tisdk-uenv/
    ├── tisdk-uenv.bbappend                # overrides U-Boot uEnv.txt
    └── tisdk-uenv/uEnv.txt                # dorprocboot=0, no EdgeAI DTB overlay
```

### Image contents (`bbai64-minimal-image`)
Console + SSH + hardware bring-up tooling, **no graphics, no EdgeAI stack**:
`bash`, dropbear SSH, `openssh-sftp-server`, `python3`, `i2c-tools`, `devmem2`,
`ethtool`, `iproute2`, `util-linux`, `procps`, `connman`/`connman-client`,
`kernel-modules`, `usb-gadget-net`.

### Key `local.conf` decisions
- `MACHINE = "beaglebone-ai64"`, `DISTRO = "arago"`
- `ARAGO_BRAND = "core"` — **important**: NOT `"edgeai"`. The `edgeai` brand injects an
  EdgeAI-specific `uEnv.txt` (with DSP/R5 overlay + `dorprocboot=1`) that we don't want
  on a minimal image.
- `DISTRO_FEATURES:remove = "wayland opengl x11 vulkan opencl"`
- `LICENSE_FLAGS_ACCEPTED = "ti-tspa synaptics-killswitch"` — required for the K3 SYSFW
  boot blobs to build.
- `EXTRA_IMAGE_FEATURES = "debug-tweaks"` — gives **root an empty password** (dev only).
- `IMAGE_FSTYPES = "wic.xz wic.bmap tar.xz"`, `INHERIT += "rm_work"`.

### Build & flash
```bash
cd /home/mohamedkhalid/tisdk
source sources/oe-core/oe-init-build-env build
bitbake bbai64-minimal-image

# then, with the microSD inserted (identify the device first!):
/home/mohamedkhalid/minimal_image/flash.sh /dev/sdX
```

### SD card layout (`sdimage-2part-efi.wks.in`)
- **Part 1** — FAT32, 128 MB: `tiboot3.bin`, `tispl.bin`, `u-boot.img`, `sysfw.itb`,
  `uEnv.txt`, GRUB-EFI, kernel `Image` + DTBs.
- **Part 2** — ext4: root filesystem.

### Verified runtime versions (read off the board)
- Kernel: **6.12.43-ti**
- U-Boot: **2025.10**
- dropbear: **2022.83**
- Board hostname: `beaglebone-ai64`, login user: **`root`** (empty password)

---

## 4. Problems encountered — root cause & fix

### Problem #0 — Layer dependency name mismatch (build-time)
**Symptom:**
`ERROR: Layer 'bbai64-minimal' depends on layer 'ti-bsp', but this layer is not enabled`

**Root cause:** `LAYERDEPENDS` must reference BitBake **collection names**, not directory
names. The TI BSP layer's collection is `meta-ti-bsp`, not `ti-bsp`.

**Fix:** `conf/layer.conf` →
`LAYERDEPENDS_bbai64-minimal = "core meta-arago-distro meta-ti-bsp openembedded-layer"`

**Avoid next time:** Get collection names from each layer's `conf/layer.conf`
(`grep BBFILE_COLLECTIONS`), never assume they match the folder name.

---

### Problem #1 — Wrong SSH username
**Symptom:** `sudo ssh debian@192.168.7.2` could not log in.

**Root cause:** `debian` is the user on **BeagleBone.org's stock Debian image**. Our Yocto
image has only **`root`** (empty password via `debug-tweaks`). Habits from the stock image
do not carry over.

**Fix:** `ssh root@<board>` and press Enter at the password prompt.

---

### Problem #2 — `192.168.7.2` is not automatic on a custom image
**Symptom:** Expected the board at `192.168.7.2` over the USB-C cable, like Debian does.

**Root cause:** The `192.168.7.x` link is **USB gadget Ethernet** (`g_ether` →
`usb0`). The stock Debian image ships this preconfigured; our minimal image originally
did not. We added the `usb-gadget-net` recipe to provide it (loads `g_ether`, assigns
`192.168.7.2`, blacklists `usb0` in connman).

**Avoid next time:** A "minimal" Yocto image has **none** of the stock Debian conveniences
(USB gadget net, mDNS/`beaglebone.local`, `debian` user, capemgr). Add each explicitly.

---

### Problem #3 — Serial console `/dev/ttyUSB2` did not exist (red herring)
**Symptom:** `minicom -D /dev/ttyUSB2 -b 115200` showed nothing; `ls /dev/ttyUSB*` empty;
`lsusb` showed no FTDI.

**Root cause:** **The BeagleBone AI-64 has no onboard USB-to-serial converter.** Unlike
the BeagleBone Black, its debug UART is a separate header that needs an **external 3.3 V
USB-TTL adapter**. With only the USB-C cable attached, no `ttyUSB*` device can appear.

**Fix / takeaway:** For serial console, wire an external USB-TTL adapter to the BBAI-64
debug header (115200 8N1). **But we never needed it** — the USB network gadget gave us a
working path in. Don't treat "no ttyUSB" as "board is dead."

---

### Problem #4 — The decisive evidence: the board was fine all along
**Observation:** `lsusb` showed
`Bus 001 Device 008: ID 0525:a4a2 Netchip ... Linux-USB Ethernet/RNDIS Gadget`,
and `dmesg` showed `cdc_ether ... renamed from usb0 → enx06f4887cb701`.

**Meaning:** `0525:a4a2` **is our `g_ether` gadget**. Its presence proved the board had
**booted, run our kernel, loaded the module, and enumerated** — i.e. the image worked.
From here on, the problem space was entirely **host-side IP configuration**.

**Avoid next time:** When "nothing works," first ask *what does the host actually see?*
(`lsusb`, `dmesg`, `ip -br addr`). The gadget's appearance is positive proof of a
successful boot.

---

### Problem #5 — Board's `usb0` never received its IPv4 address
**Symptom:** On the board, `usb0` was `UP` but had **only a link-local IPv6 address**, no
`192.168.7.2`. (Confirmed via SSH-over-IPv6-link-local — see §5.)

**Root cause:** Our address assignment used a **udev `RUN+=` rule**
(`72-usb-gadget.rules`). Assigning IPs to *network* devices from a udev `RUN` action at the
`add` event is **unreliable** — udev runs actions in a restricted, short-lived context and
the net device is often not in a configurable state at that moment. (Notably, the *name*
`usb0`, the `/sbin/ip` path, and the connman blacklist were all **correct** — connman was
properly ignoring `usb0`. The mechanism itself was the weak link.)

**Temporary fix applied (live, during bring-up):** on the board,
`ip addr add 192.168.7.2/24 dev usb0 && ip link set usb0 up`.

**Permanent fix (✅ DONE — see §6a):** the udev `RUN` rule was **removed** and replaced
with a **systemd oneshot service** bound to the `usb0` device, plus **pinned gadget MACs**
so the interface name stops changing. Built into the recipe and validated; activate by
rebuilding + reflashing.

---

### Problem #6 — Host routed `192.168.7.x` out WiFi instead of the gadget
**Symptom:** Even after the board had `192.168.7.2`, `ping 192.168.7.2` failed with 100%
loss, while **IPv6 link-local and SSH-over-IPv6 worked perfectly** over the same cable.

**Root cause (the big one):**
```
ip route get 192.168.7.2
  → 192.168.7.2 via 10.5.50.1 dev wlo1 src 10.5.50.76     # out WiFi to the router!
```
The connected `192.168.7.0/24` route for the gadget interface was **missing**, so the host
fell back to its default gateway over **WiFi (`wlo1`)**. The packets left over WiFi and
never reached the board. Compounding factors:
- **`net.ipv4.conf.*.rp_filter = 2`** (strict reverse-path filtering) — would drop the
  board's replies even if routed correctly.
- **NetworkManager** kept **flushing the gadget's manual IP/route** (it treats the gadget
  as a new managed wired device and tries DHCP). This also caused the interface to "flap"
  and lose its addresses mid-debug.

**Fix applied (host side, live):**
```bash
IFACE=enx06f4887cb701
sudo nmcli device set "$IFACE" managed no          # stop NM from touching it
sudo ip addr flush dev "$IFACE"
sudo ip addr add 192.168.7.1/24 dev "$IFACE"
sudo ip link set "$IFACE" up
sudo ip route replace 192.168.7.0/24 dev "$IFACE" src 192.168.7.1
sudo sysctl -w net.ipv4.conf.$IFACE.rp_filter=0
```
Result: `ip route get 192.168.7.2` now resolves via the gadget, ping is 0% loss, and
`ssh root@192.168.7.2` logs in.

**Avoid next time:** IPv4 needs the host to (a) hold an address on the gadget subnet,
(b) have the connected route point at the gadget interface, (c) not strict-rp_filter it,
and (d) keep NetworkManager off it. See §6 for the permanent host-side config.

---

## 5. The recovery technique that saved us — IPv6 link-local

Before any IPv4 worked, we got a shell on the board using **IPv6 link-local**, which needs
**zero configuration** and is independent of the broken IPv4 path:

```bash
# 1. Detect the host gadget interface (NEVER hardcode — name changes every plug)
IFACE=$(ip -br link | awk '/enx[0-9a-f]{12}/{print $1}' | head -1)

# 2. Discover neighbours on the link (board answers the all-nodes multicast):
ping6 -c 3 "ff02::1%$IFACE"
#   → one reply is the host itself, the OTHER is the board's fe80:: address

# 3. SSH straight to the board's link-local address (note the %iface scope):
ssh root@<board-fe80-addr>%$IFACE
```

### Anatomy of `ssh root@<board-fe80-addr>%$IFACE` — what to substitute
```
ssh root@<board-fe80-addr>%$IFACE
        │    │               │
        │    │               └─ $IFACE : the HOST's gadget interface (step 1), e.g. enxb2f129879089
        │    └─ <board-fe80-addr> : the BOARD's fe80:: address from step 2, e.g. fe80::7cca:26ff:feb6:9f89
        └─ user : always "root" on our image (empty password)
```
A fully substituted example (values from one session — **yours will differ**):
```bash
ssh root@fe80::7cca:26ff:feb6:9f89%enxb2f129879089
```

**Why the `%$IFACE` (scope/zone ID) is mandatory:** a link-local `fe80::` address is *not*
globally unique — the same range exists on every interface. The `%<iface>` suffix tells the
kernel which interface to send the packets out. Omit it and you get `Network is unreachable`.

**Keep this in the toolkit** — any time a USB-gadget board enumerates but IPv4 is
misconfigured, IPv6 link-local + `ping6 ff02::1%iface` gets you in. (Or just run
`connect-bbai64.sh`, which does all of the above automatically.)

---

## 6. Making it permanent

### ✅ 6a. Board side — IMPLEMENTED in the `usb-gadget-net` recipe (activate by reflashing)
Both board-side root-cause fixes are now **built into the image** (validated; the package
installs them and enables the service). They take effect the next time you **rebuild +
reflash** the SD card. The old fragile udev rule has been **removed**.

**(i) Pinned gadget MACs — `/etc/modprobe.d/g_ether.conf`** (stops the per-boot random MAC
that renamed the host interface every plug):
```
options g_ether dev_addr=aa:bb:cc:00:00:02 host_addr=aa:bb:cc:00:00:01
#   dev_addr  = board's usb0 MAC
#   host_addr = MAC the laptop sees → host iface becomes the CONSTANT enxaabbcc000001
```

**(ii) systemd static-IP service — `/usr/lib/systemd/system/usb0-static-ip.service`**
(replaces the unreliable udev `RUN+=`; bound to the usb0 device, enabled via preset):
```ini
[Unit]
Description=Assign static IP 192.168.7.2 to USB gadget usb0
BindsTo=sys-subsystem-net-devices-usb0.device
After=sys-subsystem-net-devices-usb0.device
[Service]
Type=oneshot
ExecStart=/bin/sh -c '/sbin/ip addr add 192.168.7.2/24 dev usb0 || true'
ExecStart=/sbin/ip link set usb0 up
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
WantedBy=sys-subsystem-net-devices-usb0.device
```
`g_ether` is still loaded at boot via `/etc/modules-load.d/g_ether.conf`, and connman still
blacklists `usb0`. **To activate: `bitbake bbai64-minimal-image` → `flash.sh /dev/sdX`.**

### ✅ 6b. Host side — INSTALLED (`bbai64-usb` NetworkManager profile)
A NetworkManager profile is already installed on this host at
`/etc/NetworkManager/system-connections/bbai64-usb.nmconnection` (chmod 600), keyed to the
**pinned** host interface name `enxaabbcc000001` (from `host_addr=aa:bb:cc:00:00:01`):

```ini
[connection]
id=bbai64-usb
type=ethernet
interface-name=enxaabbcc000001     # constant name once Fix 6a is flashed
autoconnect=true
[ipv4]
method=manual
address1=192.168.7.1/24
never-default=true                 # never use the gadget as the default route
[ipv6]
method=link-local
addr-gen-mode=eui64                # guarantees a usable fe80:: link-local
```

It currently shows `DEVICE --` (unbound) because `enxaabbcc000001` doesn't exist **until
you reflash** the image with the pinned MAC. **After reflashing**, plugging in the board
makes everything automatic — host gets `192.168.7.1`, board gets `192.168.7.2` (systemd
service), and `ssh root@192.168.7.2` just works with **no scripts**.

> Why `rp_filter` no longer needs tweaking: with this profile NM installs the correct
> connected route on the gadget, so strict reverse-path filtering (`rp_filter=2`) passes —
> the earlier drop only happened because the route was wrongly pointing at WiFi.

**Until you reflash**, the gadget MAC is still random, so keep using
`board-login.sh` / `connect-bbai64.sh` to connect.

---

## 7. Quick reference / runbook

> ⚠️ **DO NOT hardcode the host gadget interface name or the board's IPv6
> link-local address.** The `g_ether` gadget randomizes its **host-side MAC on
> every plug/boot**, so the host interface name (`enxXXXXXXXXXXXX`) and the
> discovered link-local change every time. Always auto-detect. (The board's own
> `usb0` MAC happens to be stable, but don't rely on it either.)

### Easiest: run the login script — it configures everything AND logs you in
```bash
/home/mohamedkhalid/minimal_image/board-login.sh
```
`board-login.sh` does the full host setup (detect gadget iface, unmanage in NM, fix IPv6
`addr_gen_mode`, assign `192.168.7.1/24` + route + `rp_filter=0`), reaches the board over
IPv6 link-local to set its `usb0` IP if missing, then **drops you straight into the board's
root shell** (type `exit` to return). Run it in your own terminal.

There is also `connect-bbai64.sh`, which only *configures* the host/board and leaves you to
run `ssh root@192.168.7.2` yourself — useful for scripting/automation.

### Manual equivalent (if you need to do it by hand)
```bash
# 1. Detect the CURRENT gadget iface (name changes every plug!)
IFACE=$(ip -br link | awk '/enx[0-9a-f]{12}/{print $1}' | head -1); echo "$IFACE"

# 2. Host side: unmanage + IPv6 LL + IPv4 + route + rp_filter
sudo nmcli device set "$IFACE" managed no
sudo sysctl -w net.ipv6.conf.$IFACE.addr_gen_mode=0      # else no IPv6 LL generates!
sudo ip addr flush dev "$IFACE"
sudo ip link set "$IFACE" down; sleep 1; sudo ip link set "$IFACE" up; sleep 3
sudo ip addr add 192.168.7.1/24 dev "$IFACE"
sudo ip route replace 192.168.7.0/24 dev "$IFACE" src 192.168.7.1
sudo sysctl -w net.ipv4.conf.$IFACE.rp_filter=0

# 3. Discover the board's CURRENT link-local (exclude our own LL)
HOST_LL=$(ip -6 addr show dev "$IFACE" scope link | awk '/inet6/{print $2}' | cut -d/ -f1)
ping6 -c4 "ff02::1%$IFACE" | awk -F'from ' '/bytes from/{print $2}' \
   | cut -d% -f1 | sort -u | grep -v "^$HOST_LL$"      # → board fe80:: address

# 4. SSH over IPv6 LL and set the board's usb0 IPv4
ssh root@<board-fe80-addr>%$IFACE 'ip addr add 192.168.7.2/24 dev usb0; ip link set usb0 up'

# 5. Now the normal address works:
ssh root@192.168.7.2

# ---- Alternate path: the board is also on wired LAN ----
#   board eth0 gets a DHCP address (was 192.168.8.117/24). Reachable if your host
#   shares that subnet:  ssh root@<eth0-dhcp-ip>
```

### Session reference values (this board / host)
| | |
|---|---|
| Board hostname | `beaglebone-ai64` |
| Board user | `root` (empty password) |
| Board `usb0` IPv4 (we assign) | `192.168.7.2/24` |
| Board `usb0` IPv6 LL | `fe80::7cca:26ff:feb6:9f89` — **observed stable**, but verify each time |
| Board `eth0` (LAN/DHCP) | was `192.168.8.117/24` (DHCP — will vary) |
| Host gadget IPv4 (we assign) | `192.168.7.1/24` |
| USB gadget USB ID | `0525:a4a2` (Linux-USB Ethernet/RNDIS Gadget) |
| Host gadget iface name | **CHANGES EVERY PLUG** — e.g. `enx06f4887cb701`, `enx16d57d60c711`, `enxfa247f5fb682`, `enxb2f129879089` … auto-detect it |

> ⚠️ **Root cause of "it worked before, now it doesn't":** `g_ether` generates a
> **random host-side MAC each boot/replug**, so the host interface name and the
> link-local discovery target change every time. Never hardcode them. The real fix
> is to **pin the gadget MAC** (Fix A in §6) so names/addresses stop moving.

---

## 8. Top lessons for future phases

1. **Trust the evidence, not stock-image habits.** `debian`/`192.168.7.2`/`beaglebone.local`
   are Debian-image conveniences; a minimal Yocto image has none unless we add them.
2. **The USB gadget appearing in `lsusb` = the board booted successfully.** Start every
   debug session with `lsusb`, `dmesg`, `ip -br addr` on the host.
3. **IPv6 link-local is a zero-config rescue path** over any USB-gadget link.
4. **USB gadget IPv4 needs four host-side things:** an address on the subnet, a connected
   route to the gadget iface, relaxed `rp_filter`, and NetworkManager kept off the iface.
5. **Don't assign net-device IPs from udev `RUN+=`** — use a systemd device-bound service.
6. **BBAI-64 has no onboard serial** — `ttyUSB*` won't appear without an external USB-TTL
   adapter; absence of it is not a fault.
7. **Layer `LAYERDEPENDS` uses collection names**, not directory names.
8. **Keep `rm_work` on** — host free space is tight (~15 GB).
