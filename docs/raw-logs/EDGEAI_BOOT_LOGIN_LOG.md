# EdgeAI image — flash, connect & login log (2026-06-20)

Step-by-step record of flashing `tisdk-edgeai-image`, confirming the board is
connected, and logging in. Written so it can be repeated by someone who is new to
this. Every command and every "why/calculation" is included.

**Result:** ✅ Board boots `tisdk-edgeai-image` (Linux 6.12.43-ti, Arago 2025.01)
and is reachable at `ssh root@192.168.7.2` (empty password).

---

## 0. Background — the two boot bugs we had already fixed

The BeagleBone AI-64 (BBAI-64, TI J721E) boots in a chain:

```
ROM  ->  tiboot3.bin (R5 SPL)  ->  sysfw.itb (system firmware)  ->  tispl.bin
     ->  u-boot.img (U-Boot)   ->  uEnv.txt (boot command)       ->  Linux kernel (Image + DTB)
```

Two pieces had been missing from the SD card's first (FAT) partition, which is why
the board earlier looked "dead" (only the PWR LED, no heartbeat):

1. **Stage 1 — `sysfw.itb` was missing.** J721E uses *split boot*: the R5 SPL loads
   the system firmware from a file named exactly `sysfw.itb`. A previous
   `do_image_wic` workaround had deleted it. **Permanent fix** is now in
   `build/conf/local.conf`:
   ```
   IMAGE_BOOT_FILES:append = " sysfw-j721e-gp-evm.itb;sysfw.itb"
   ```
   So every freshly built `.wic` now contains `sysfw.itb` automatically (verified
   present in this build).

2. **Stage 2 — no kernel boot payload.** The build ships `EFI/BOOT/grub.cfg` but no
   grub binary, and no device tree (DTB) file, and the stock edgeai `uEnv.txt` has a
   `uenvcmd` that only tweaks a hostname for a different board and never boots. So we
   add, onto the card after flashing: the base DTB + a `uEnv.txt` that explicitly
   loads the kernel. (This part is applied per-card for now; see §6.)

---

## 1. Flash the edgeai image to the SD card

Card was in the laptop's SD reader as `/dev/sdb` (verify with `lsblk` first — it must
be the 58.3 GB removable card, NOT a system disk).

```bash
cd /home/mohamedkhalid/minimal_image
echo "yes" | ./flash.sh /dev/sdb tisdk-edgeai-image
```

What this does: `flash.sh` uses `bmaptool` to write only the *used* blocks of
`tisdk-edgeai-image-...rootfs.wic.xz` (decompressing on the fly) to the card.

**Numbers from this run:**
- Image total size: 3,115,089 blocks × 4096 B = **11.9 GiB** (the full card layout).
- Actually written (mapped/used blocks): 1,757,366 × 4096 B = **6.7 GiB** (= 56.4 %).
  bmap skips empty space, so only 6.7 GiB is copied, not 11.9 GiB.
- Time: 6 min 51 s at ~16.7 MiB/s.

---

## 2. Apply the stage-2 boot payload to the card (after flashing)

Mounted the card's boot partition (`/dev/sdb1`) and added the DTB + an explicit boot
`uEnv.txt`. Key facts:

- Rootfs partition UUID (so the kernel knows where `/` is):
  `blkid -s PARTUUID -o value /dev/sdb2` → **`076c4a2a-02`**
- The `uEnv.txt` we wrote (the important line is `uenvcmd`):
  ```
  dorprocboot=0
  loadaddr=0x82000000
  fdt_addr_r=0x88000000
  uenvcmd=setenv bootargs console=ttyS2,115200n8 root=PARTUUID=076c4a2a-02 rootwait rootfstype=ext4 ; \
          for d in 1 0 ; do if load mmc ${d}:1 ${loadaddr} Image ; then \
          load mmc ${d}:1 ${fdt_addr_r} k3-j721e-beagleboneai64.dtb ; \
          booti ${loadaddr} - ${fdt_addr_r} ; fi ; done
  ```
  **What it means:** load the kernel `Image` into RAM at `0x82000000`, load the device
  tree into RAM at `0x88000000`, then `booti` (boot an arm64 kernel). The `for d in 1 0`
  tries SD (`mmc 1`) then eMMC (`mmc 0`). `dorprocboot=0` = do NOT start the AI
  co-processors at boot (safe first boot).
- Address choice: board DRAM starts at `0x80000000`. Kernel at `0x82000000` (32 MiB in),
  DTB at `0x88000000` (128 MiB in) — far enough apart that the 42 MiB kernel image
  (`0x82000000`–`0x84800000`) never overlaps the DTB.

Boot-chain files confirmed on the card: `tiboot3.bin`, `sysfw.itb`, `tispl.bin`,
`u-boot.img`, `Image`, `k3-j721e-beagleboneai64.dtb`, `uEnv.txt`. ✅

Then the user inserted the card into the board, held the **BOOT** button (forces SD
boot instead of eMMC), and powered it on via USB-C.

---

## 3. STEP 1 — Check the board is connected (host side)

```bash
lsusb | grep -i '0525:a4a2'
sudo dmesg | grep -iE '0525|cdc_ether|Gadget|usb0' | tail
ip -br link
```

**Found:**
```
Bus 001 Device 024: ID 0525:a4a2 Netchip ... Linux-USB Ethernet/RNDIS Gadget
cdc_ether 1-4:1.0 usb0: register 'cdc_ether' ... CDC Ethernet Device, aa:bb:cc:00:00:01
cdc_ether 1-4:1.0 enxaabbcc000001: renamed from usb0
```

**Meaning:**
- USB ID `0525:a4a2` is the board's USB‑Ethernet gadget. **Its presence = the board
  booted Linux successfully** (only a running kernel creates this).
- `Manufacturer: Linux 6.12.43-ti` confirms our kernel.
- The host-side interface is **`enxaabbcc000001`**. The name comes directly from the
  pinned MAC `aa:bb:cc:00:00:01` (`enx` + the 12 hex digits of the MAC). Because the MAC
  is pinned, this name is **constant every boot** (it used to randomize).

---

## 4. STEP 2 — Configure the host end of the USB link

The USB gadget is a private 2‑computer Ethernet cable. We pick:
`HOST = 192.168.7.1/24`, `BOARD = 192.168.7.2/24` (a /24 = 256 addresses,
192.168.7.0–255; both ends share it).

Four things are required for IPv4 to work (each command maps to one):
```bash
IFACE=enxaabbcc000001
sudo nmcli device set "$IFACE" managed no                         # (d) keep NetworkManager off it
sudo sysctl -qw net.ipv6.conf.$IFACE.disable_ipv6=0              # enable IPv6...
sudo sysctl -qw net.ipv6.conf.$IFACE.addr_gen_mode=0            # ...so a link-local exists (rescue path)
sudo ip addr flush dev "$IFACE"
sudo ip link set "$IFACE" down; sleep 1; sudo ip link set "$IFACE" up; sleep 3
sudo ip addr add 192.168.7.1/24 dev "$IFACE"                     # (a) host IP on the subnet
sudo ip route replace 192.168.7.0/24 dev "$IFACE" src 192.168.7.1 # (b) route the subnet OUT this iface
sudo sysctl -qw net.ipv4.conf.$IFACE.rp_filter=0                # (c) relax reverse-path filtering
```

Verify the kernel will send 192.168.7.2 out the gadget (and not the WiFi gateway):
```bash
ip route get 192.168.7.2
# -> 192.168.7.2 dev enxaabbcc000001 src 192.168.7.1   ✅ (out the gadget)
```

First ping failed with **"Destination Host Unreachable"** — that specific error means
the board didn't answer ARP, i.e. its `usb0` did not have `192.168.7.2` yet (a known
timing quirk of the board's static-IP service; see §6). So we used the rescue path.

---

## 5. STEP 3+4 — IPv6 link-local rescue, then LOGIN

IPv6 *link-local* (`fe80::/10`) needs **zero configuration** — every interface gets one
automatically, derived from its MAC by the **EUI-64** rule. We use it to reach the board
even when IPv4 isn't set up yet.

**EUI-64 calculation for the board (MAC `aa:bb:cc:00:00:02`):**
1. Split MAC in half, insert `ff:fe` in the middle:
   `aa:bb:cc | ff:fe | 00:00:02`
2. Flip bit 1 (the 2nd-lowest bit) of the first byte:
   `aa` = `1010 1010` → flip → `1010 1000` = `a8`
3. Result: **`fe80::a8bb:ccff:fe00:2`** ← the board's link-local address.
   (Host, MAC `aa:bb:cc:00:00:01`, becomes `fe80::a8bb:ccff:fe00:1`.)

Discover it live (one reply is us, the other is the board):
```bash
ping6 -c3 ff02::1%enxaabbcc000001       # ff02::1 = "all nodes on this link"
# replies from fe80::a8bb:ccff:fe00:1 (host) and fe80::a8bb:ccff:fe00:2 (board)
```

**Log in over the link-local address** (note the `%enxaabbcc000001` zone suffix — it tells
the kernel which interface to use, mandatory for fe80:: addresses), set the board's IPv4:
```bash
sshpass -p '' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  root@fe80::a8bb:ccff:fe00:2%enxaabbcc000001 \
  'ip addr add 192.168.7.2/24 dev usb0; ip link set usb0 up'
```
User = **root**, password = **empty** (the image was built with `debug-tweaks`).

After that, the normal address works for all future logins:
```bash
ping -c2 192.168.7.2          # 0% loss ✅
ssh root@192.168.7.2          # (empty password)
```

---

## 6. STEP 5 — Verification (what's confirmed working)

| Check | Result |
|---|---|
| `ssh root@192.168.7.2` | ✅ works (0% packet loss) |
| Kernel | `Linux beaglebone-ai64 6.12.43-ti` (PREEMPT_RT, aarch64) |
| Distro | Arago 2025.01 |
| Booted from | `/dev/mmcblk1p2` = the **SD card** (eMMC = `mmcblk0`, untouched) |
| edgeai apps | `/opt/edgeai-gst-apps` present |
| TIDL runtime | present (`tidlruntime` python module) |
| AI remote-cores | mostly `offline` (1 `attached`) — expected, because `dorprocboot=0` |

**Why the remote-cores are offline:** we booted with `dorprocboot=0` on purpose, so
U-Boot does not start the C7x DSP / R5 firmware. The board boots reliably this way and
the whole edgeai userland is present. The AI co-processors can be brought up later from
the running shell (Linux `remoteproc`), which is far safer than doing it blind in U-Boot.

**Known minor issues (not blocking):**
- `usb0-static-ip.service` runs at boot but its `ip addr add` can fire before the `usb0`
  interface exists, so `192.168.7.2` isn't always set automatically (we set it manually
  over the rescue path). Cosmetic timing bug.
- `psplash-start.service` shows "failed" — harmless boot-splash, no display attached.

---

## 7. How to reconnect later (quick reference)

```bash
# 1. plug board USB-C into the laptop, hold BOOT, power on. Wait for heartbeat LED.
# 2. on the laptop:
IFACE=$(ip -br link | awk '/enxaabbcc000001|^usb0/{print $1}' | head -1)
sudo nmcli device set "$IFACE" managed no
sudo ip addr add 192.168.7.1/24 dev "$IFACE" 2>/dev/null
sudo ip link set "$IFACE" up
sudo ip route replace 192.168.7.0/24 dev "$IFACE" src 192.168.7.1
sudo sysctl -qw net.ipv4.conf.$IFACE.rp_filter=0
ssh root@192.168.7.2            # empty password
# If 192.168.7.2 is unreachable, use the rescue path in §5.
```

Or just run the existing helper: `/home/mohamedkhalid/minimal_image/board-login.sh`

---

## 8. Next step (optional) — enable the AI accelerators

Now that we have a shell, bringing up the C7x/R5 firmware can be done from Linux
(`remoteproc`) and tested live, or by switching the card to `dorprocboot=1` + the
`k3-j721e-edgeai-apps.dtbo` overlay. To make a *rebuilt* edgeai image boot hands-off
(no per-card editing), the build still needs its stage-2 payload fixed (deploy the grub
binary, or bake the DTB + an explicit `uEnv` into the boot files via the recipe).
