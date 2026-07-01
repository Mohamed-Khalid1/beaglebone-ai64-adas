# BeagleBone AI-64 — Login Guide (USB-C from a laptop)

How to SSH into the board over the **USB-C network gadget** from any Linux laptop. Tested working;
covers the normal path **and** the IPv6 rescue path for when the board's IPv4 isn't set.

> **Board facts:** user **`root`**, **empty password** (just press Enter). Hostname
> `beaglebone-ai64`. The board exposes a USB **Ethernet/RNDIS gadget** (`lsusb` id `0525:a4a2`),
> board IP `192.168.7.2`, host IP `192.168.7.1`. Board's pinned MAC = `aa:bb:cc:00:00:02`, so its
> IPv6 link-local is **`fe80::a8bb:ccff:fe00:2`**.

---

## 0. Prerequisites (read this — most failures are here)
1. **Use a DATA-capable USB-C cable.** Charge-only cables are the #1 cause of "nothing happens."
2. Plug into the board's **USB-C gadget port** (the one that enumerates the network device).
3. Power the board and **wait ~30–40 s after boot** — the gadget enumerates *after* Linux boots.
4. **Verify the board is seen at the USB level first:**
   ```bash
   lsusb | grep -i 0525:a4a2     # → "Netchip ... Linux-USB Ethernet/RNDIS Gadget" = board OK
   ```
   If this prints nothing, it's a cable/port/boot problem — fix that before anything else.

---

## 1. Find the host interface name
On first plug the gadget often appears as **`usb0`**; after a board reset it may appear as
**`enxaabbcc000001`** (named from the pinned MAC). Auto-detect it:
```bash
IFACE=$(ip -br link | awk '/^(usb0|enx[0-9a-f]{12})/{print $1; exit}')
echo "gadget iface = $IFACE"
```

## 2. Configure the host side (one-time per plug)
```bash
sudo ip addr add 192.168.7.1/24 dev "$IFACE" 2>/dev/null   # host IP (ignore "File exists")
sudo ip link set "$IFACE" up
nmcli dev set "$IFACE" managed no 2>/dev/null               # keep NetworkManager off it
# make sure return traffic isn't dropped by reverse-path filtering:
sudo sysctl -w net.ipv4.conf."$IFACE".rp_filter=0 >/dev/null 2>&1
```

## 3a. Normal login — IPv4 (try this first)
```bash
ping -c2 192.168.7.2          # should reply
ssh root@192.168.7.2          # password = just press Enter
```
No-prompt one-liner (skips host-key/known-hosts noise):
```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    root@192.168.7.2
```

## 3b. Rescue login — IPv6 link-local (use if `192.168.7.2` doesn't ping)
On some boots the board doesn't self-assign `192.168.7.2`. IPv6 link-local **always** works:
```bash
# discover the board (it answers the all-nodes multicast):
ping6 -c3 "ff02::1%$IFACE"        # look for a reply from fe80::a8bb:ccff:fe00:2

# log in over IPv6 — NOTE the '-6' flag and the %iface zone are REQUIRED:
ssh -6 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    "root@fe80::a8bb:ccff:fe00:2%$IFACE"
```
> ⚠️ Plain `ssh root@fe80::...%iface` (without `-6`) fails with **"Network is unreachable"** because
> ssh tries IPv4 first. **Always pass `-6`** for the link-local path.

### Optional: restore IPv4 from inside the rescue session
Once logged in via IPv6, you can give the board its IPv4 so the easy path works again:
```bash
ip addr add 192.168.7.2/24 dev usb0 2>/dev/null; ip link set usb0 up
```
(`usb0` is the board-side gadget iface name; adjust if different.)

---

## 4. One-shot copy-paste (does steps 1–3a, falls back to 3b)
```bash
IFACE=$(ip -br link | awk '/^(usb0|enx[0-9a-f]{12})/{print $1; exit}')
sudo ip addr add 192.168.7.1/24 dev "$IFACE" 2>/dev/null
sudo ip link set "$IFACE" up
nmcli dev set "$IFACE" managed no 2>/dev/null
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no"
if ping -c1 -W2 192.168.7.2 >/dev/null 2>&1; then
    ssh $SSHOPT root@192.168.7.2
else
    echo "IPv4 down — using IPv6 rescue"
    ssh -6 $SSHOPT "root@fe80::a8bb:ccff:fe00:2%$IFACE"
fi
```

## 5. Copying files to/from the board
```bash
# IPv4:
scp $SSHOPT myfile root@192.168.7.2:/home/root/
# IPv6 (note the [brackets] around the address for scp):
scp -6 $SSHOPT myfile "root@[fe80::a8bb:ccff:fe00:2%$IFACE]:/home/root/"
```
USB-gadget throughput is ~**25 MB/s**. Use `/home/root/` (persistent SD-card storage) for anything
that must survive a reboot — **`/tmp` is wiped on every boot**.

---

## 6. Troubleshooting quick table
| Symptom | Cause / fix |
|---|---|
| `lsusb` shows no `0525:a4a2` | Charge-only cable, wrong port, or board still booting. Reseat a **data** cable. |
| Host iface is `usb0` not `enx...` | First plug after boot (random gadget MAC). Normal — just use `$IFACE` auto-detect. |
| `ping 192.168.7.2` 100% loss | Board didn't self-assign IPv4 this boot → use the **IPv6 rescue** (3b). |
| ssh `Network is unreachable` (v6) | You forgot **`-6`**. Add it. |
| ssh `No route to host` (v4) | Host iface has no `192.168.7.1` / NetworkManager grabbed it → redo step 2. |
| Connection drops mid-session | Gadget/cable instability — reseat cable; the board itself stays up (check `lsusb`). |
| ssh banner timeout | Board still finishing boot, or briefly busy — wait and retry. |

**Confirmed working:** `ssh -6 root@fe80::a8bb:ccff:fe00:2%usb0` → `beaglebone-ai64`, login as `root`
with an empty password.
