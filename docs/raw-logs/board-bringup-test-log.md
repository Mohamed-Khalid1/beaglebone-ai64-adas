# Board bring-up test log — flash 11.00 image → login → TIDL/C7x tests (2026-06-25)

Detailed, reproducible log of every step taken after the 11.00-baseline
`tisdk-edgeai-image` was flashed. Companion to `bringup-status-notes.md` (Phase 7 plan).

**One-line status:** ✅ **TIDL on C7x WORKS on the 11.00 baseline.** Image flashes, boots,
all 6 compute cores run, full IPC mesh + `/dev/remoteproc0`, and a classification model
(`ONR-CL-6360-regNetx-200mf`) **offloaded 103/103 nodes to the C7x, inference OK in
4.4 ms, exit 0** — no io.bin-size mismatch, no `cmd_status -1` net-version reject. The
whole Phase 4–6 version-skew saga is resolved by the clean 11.00 rebaseline.

**Caveat:** the *heavy* `ONR-KD-7060-human-pose-yolox-s-640x640` model (which the smoke
test auto-discovers first) **hangs / resets the board** at the A72↔DSP rpmsg setup. Use a
known-good model (the regnetx classification model) or investigate per-model before the
custom YOLO. Details in Test 5.

---

## 0. Pre-flight (host)

| Check | Result |
|---|---|
| Artifact | `tisdk-edgeai-image-beaglebone-ai64.rootfs-20260624214902.wic.xz` (1.05 GB) + `.wic.bmap` ✓ |
| `…rootfs.wic.xz` symlink | → 20260624214902 build ✓ |
| SD card node | **`/dev/sdb`** (14.4 GB, "SD/MMC/MS PRO", USB). System disks `sda`/`nvme0n1` (guarded) |
| sudo | passwordless ✓ |
| bmaptool | `/usr/bin/bmaptool` ✓ |

## 1. Flash (part A)

```bash
echo "yes" | /home/mohamedkhalid/minimal_image/flash.sh /dev/sdb tisdk-edgeai-image
```
- bmaptool wrote **6.4 GB** (mapped 1 680 374/2 991 337 blocks), 9m03s @ 12.1 MiB/s, synced. ✓
- Re-read table: `sdb1` 128M vfat **BOOT**, `sdb2` 11.3G ext4 **rootfs** (auto-expanded). ✓

### On-card verification (mounted read-only on host before ejecting)
- **BOOT (`sdb1`):** `sysfw.itb`, `sysfw-j721e-gp-evm.itb`, `tiboot3.bin`, `tispl.bin`,
  `u-boot.img`, `uEnv.txt`. uEnv is SD-boot: `bootpart=1:2`,
  `fdtfile=ti/k3-j721e-beagleboneai64.dtb`,
  `name_overlays=ti/k3-j721e-edgeai-apps.dtbo`, `uenvcmd=run bootcmd_ti_mmc`. ✓
- **rootfs (`sdb2`):** kernel `Image-6.6.58-ti` ✓; DTB `k3-j721e-beagleboneai64.dtb` +
  overlay `k3-j721e-edgeai-apps.dtbo` (in `/boot/dtb/ti/`) ✓; model zoo
  `/opt/model_zoo/` incl. `ONR-CL-6360-regNetx-200mf` (11_00_04_00 set) ✓; remote-core
  firmware `j7-c71_0-fw`, `j7-c66_{0,1}-fw`, `j7-main-r5f0_{0,1}-fw` ✓; os-release =
  Arago 2025.01.
- **Staged** `tidl_smoke_test.py` → `/root/tidl_smoke_test.py` (was not on the image).
- Unmounted cleanly. (User physically moved card to board + powered it.)

## 2. Login (part B)

> ⚠️ The pinned host iface name is **not stable on the very first plug**. On cold boot
> the gadget enumerated as `cdc_subset`/random MAC → host named it **`usb0`**. After the
> board's first reset it re-enumerated as `cdc_ether` with the pinned MAC
> `aa:bb:cc:00:00:01` → host renamed it **`enxaabbcc000001`**. **Auto-detect, don't
> assume.** `rc.sh` hardcodes `enxaabbcc000001`, which is wrong on the first plug.

Discovery that works regardless of iface name:
```bash
IFACE=$(ip -br link | awk '/enx[0-9a-f]{12}/{print $1}' | head -1); [ -z "$IFACE" ] && IFACE=usb0
sudo ip link set $IFACE up
sudo ip addr add 192.168.7.1/24 dev $IFACE 2>/dev/null
sudo sysctl -qw net.ipv4.conf.$IFACE.rp_filter=0
# board announces itself; confirm + grab its pinned IPv6 LL:
sudo timeout 8 tcpdump -i $IFACE -n            # shows LLDP "beaglebone-ai64" + RS from fe80::a8bb:ccff:fe00:2
SO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
sshpass -p '' ssh $SO root@fe80::a8bb:ccff:fe00:2%$IFACE   # empty password
```
- **First boot was slow** (~9 min uptime when first reached; rootfs resize + 6 remoteproc
  loads + edgeai services). IPv4 `192.168.7.2` was NOT auto-assigned; set it by hand on
  the board (`ip addr add 192.168.7.2/24 dev usb0`). IPv6 link-local
  `fe80::a8bb:ccff:fe00:2` is the reliable path.
- Identity: `uname -r` = **6.6.58-ti** ✓, Arago 2025.01 ✓, host `lsusb` = `0525:a4a2` ✓.

## 3. Tests (part C)

### Test 1 — boot/identity ✓ PASS
Kernel 6.6.58-ti, Arago 2025.01, gadget on USB. (See §2.)

### Test 2 — remoteproc cdev + core states ✓ PASS (big improvement)
- **`/dev/remoteproc0` … `/dev/remoteproc18` now exist** (the dma_buf cdev nodes the old
  stack never had).
- Core states:
  | core | state |
  |---|---|
  | `64800000.dsp` (C7x+MMA) | **running** ✓ |
  | `4d80800000.dsp` (C66_0) | running ✓ |
  | `4d81800000.dsp` (C66_1) | running ✓ |
  | `5c00000.r5f` (main R5F mcu2_0) | running ✓ |
  | `5d00000.r5f` (main R5F mcu2_1) | running ✓ |
  | `41000000.r5f` (mcu R5F / DM) | attached ✓ |
  | `5e00000.r5f` (mcu3) | offline — `j7-main-r5f1_0-fw` load -2 (no fw; **expected/benign**) |
  | PRU/RTU/txPRU ×9 | offline (industrial, unused — benign) |

### Test 3 — DT overlay applied ✓ PASS
`dmesg`: C66_0/C66_1/R5F mcu2_0/mcu2_1 all "booting fw … now up"; C7x boots
`j7-c71_0-fw` (size 13 234 320) → "remote processor 64800000.dsp is now up".
- **No `bad phdr` errors** (the whole point of the new vision-apps memory map) ✓
- Benign notes: `remoteproc3: unsupported resource 65538` during C7x boot (non-fatal
  resource-table entry the kernel rproc ignores); `remoteproc6 (5e00000.r5f)` fw -2
  (mcu3, no firmware).

### Test 4 — rpmsg / IPC mesh ✓ PASS (channels present)
`/sys/bus/rpmsg/devices/` has, on **virtio1–5**: `rpmsg_chrdev.-1.13`,
**`rpmsg_chrdev.-1.21`** (endpoint 0x15 — the one libtivision_apps wants),
`rpmsg_ctrl.0.0`, `rpmsg_ns.53.53`, `ti.ipc4.ping-pong.-1.14`. `dmesg`: "rpmsg host is
online" for virtio1–5, channels created at addr 0xd and **0x15**. No timer-contention
stalls.

### Test 5 — TIDL inference on C7x ✅ PASS (with caveat)

**Run with a classification model — SUCCESS:**
```bash
python3 /root/tidl_smoke_test.py /opt/model_zoo/ONR-CL-6360-regNetx-200mf
```
```
Final number of subgraphs created are : 1, - Offloaded Nodes - 103, Total Nodes - 103
inference OK: 1 output(s), first shape (1, 1000), 4.4 ms
RESULT: TIDL inference ran on the C7x.
EXIT=0
```
- **103/103 nodes offloaded to the C7x** (full offload, zero CPU-fallback nodes).
- **No** `Config file size does not match` (io.bin 94616 ✓), **no** `cmd_status -1`
  net-version reject, **no** `_rpmsg_char_find_ctrldev` warnings on this clean run.
- C7x stayed `running` and the board did **not** reboot. The 11.00 rebaseline fixes the
  io.bin-size + net-version skew that blocked Sessions 4–6.

**Repeatability (confirmed):** ran regnetx **twice on the same boot** — run #1 and run #2
both `Offloaded Nodes 103/103`, inference OK **4.4 / 4.3 ms**, EXIT=0. Board stayed up
(uptime 19 min across both runs, C7x `running`). **Fully repeatable and stable.**

**Run with the heavy pose model — REPRODUCIBLY RESETS THE BOARD:**
`tidl_smoke_test.py /opt/model_zoo/ONR-KD-7060-human-pose-yolox-s-640x640`
(yolox-s pose, 640×640). io.bin = **94616** (same as regnetx → **not** a size mismatch).
- **Confirmed 2×:** both attempts **reset the board** within seconds of `sess.run`. Host
  dmesg shows the gadget unregister then re-enumerate (`cdc_ether ... enxaabbcc000001`
  device #8, later #10) ~14 s later; board uptime drops to ~1–4 min. No pstore/panic
  record (hard watchdog disabled) → firmware/system-level reset, **not** a clean Linux
  panic. The `/root/pose.log` never persisted (reset before ext4 flush).
- One of the earlier attempts (on a board that had already crashed once) instead **hung**
  at `readlink failed for .../5c00000.r5f` + `_rpmsg_char_find_ctrldev: could not find the
  matching rpmsg_ctrl device for virtio{1,2,4}.rpmsg_chrdev.-1.21` — a degraded-state
  variant of the same instability.
- Board **auto-recovers** (reboots cleanly, C7x back to `running`) — no power-cycle needed.

## 4a. Memory analysis — the carveouts are NOT the bottleneck (evidence)

Pulled the on-card compilation artifacts + reserved-memory map and compared the crashing
pose model vs. the working classifier. **The DT carveouts are not the limiting factor;
adjusting the overlay will not fix the pose crash.**

**Board reserved-memory (from `/sys/firmware/devicetree/base/reserved-memory` + `/proc/iomem`):**
| region | addr | size |
|---|---|---|
| `vision_apps_shared-memories` (dma-heap `carveout_vision_apps_shared-memories`) | `0xb8000000` | **512 MB** |
| `vision-apps-dma-memory` | `0xac000000` | 96 MB |
| `vision-apps-c71-memory` (C7x fw + heaps) | `0xb2100000` | 95 MB |
| `vision-apps-c71-dma-memory` | `0xb2000000` | 1 MB |
| `vision-apps-core-heap-memory-lo/hi` | `0xd8000000` / `0x880000000` | 192 MB / 624 MB |

**Model demand (from each model's `run.log` perfsim + `param.yaml`/`config.yaml`):**
| | regnetx-200mf (works) | yolox-s-pose 640 (crashes) |
|---|---|---|
| input | 3×224×224 | 3×**640×640** |
| TIDL layers | 71 | 129 (274 graph nodes) |
| GMACs | 0.20 | **15.85** (≈80×) |
| `perfsim_ddr_transfer_mb` | 2.76 | **24.21** |
| peak activation | 32×112×112 (~0.4 MB) | 32×320×320 (~3.3 MB) |
| compile memory planning | `Successful Memory Allocation` | `Successful Memory Allocation` |
| target_device | TDA4VM (J721E) ✓ | TDA4VM (J721E) ✓ |
| **detection-output layer on DSP** | **none** (classifier) | **YES** — `TIDL_DetectionOutputLayer` + `TIDL_OdOutputReformatLayer`, `object_detection:meta_arch_type 6`, needs a runtime `.prototxt`, `top_k 200` |

**Conclusion:** peak DDR transfer is **24 MB** against a **512 MB** shared heap, and TIDL's
own compile-time memory planning reports **"Successful Memory Allocation"** for the correct
**TDA4VM** target. DDR is nowhere near exhausted → a bigger reserved-memory carveout cannot
be the fix. The two real differentiators are (1) the much heavier 640×640 / 15.85-GMAC
workload with large early feature maps that must be tiled through on-chip **L2/MSMC** SRAM
(firmware-defined, **not** settable via device tree), and (2) the **on-DSP
detection-output / OD-meta-arch layer**, which the classifier doesn't have and which is the
classic version-/firmware-sensitive TIDL component. The crash correlates with the OD layer,
not with DDR.

## 4b. Implication for the teammate's YOLOv26n lane model

The custom model is an **object detector with a detection head — the same risky class as
the pose model that crashed**, not the safe class of the classifier that worked. Before
deploying it on-board:
1. **Compile on x86** with the 11.00-matching tidl-tools (`~/edgeai-tidl-tools`) and read
   the perfsim/`run.log`: confirm `num_subgraphs`/offload, `perfsim_ddr_transfer_mb`, and
   `Successful Memory Allocation`.
2. **Do detection post-processing on the A72/CPU, not the DSP** — i.e. compile so TIDL
   outputs the raw head tensors and run NMS/decode in Python/OpenCV, *or* match the
   tidl-tools version to the on-board runtime/firmware exactly. The on-DSP OD layer is the
   prime suspect for the reset.
3. Keep input resolution moderate (e.g. 320–512) and `tensor_bits: 8`.
4. Validate one inference on a *fresh* boot; if it resets, it is **not** a DT carveout fix.

> **Note (not a DDR fix):** the original hypothesis "enlarge the reserved heaps" is
> disproven by the numbers above — left here so it isn't re-tried.

## 4c. Test-harness footgun

`tidl_smoke_test.py` with no arg auto-discovers the **first** model under `/opt/model_zoo`
(alphabetically `ONR-KD-7060-…pose…`), i.e. it defaults to the model that crashes the
board. Always pass an explicit model dir, or change the auto-discovery to prefer a
classifier. A crash now requires a **manual power-cycle** (see §USB note).

## §USB note (corrected)

After a pose-model crash the **USB gadget does NOT re-appear on the host on its own** — the
board must be **manually power-cycled** to restore the network. (The "auto-recovered"
re-enumeration seen earlier in host dmesg was *after* a manual power-cycle, not automatic.)

## 4. Read of the per-model instability

The TIDL/C7x path itself is **working** (classification model: full offload + inference).
The heavy pose model destabilizes the A72↔DSP IPC bring-up — either model-specific
(its artifacts/size) or aggravated when the board had already crashed once and remoteproc
was in a fragile state. The `_rpmsg_char_find_ctrldev` "could not find matching rpmsg_ctrl"
lines are **non-fatal warnings** (the lib retries other virtio buses) — they appeared only
on the failing/heavy runs and were **absent (count 0)** on the clean successful run, so
they are a symptom, not the root cause. Before running the teammate's custom YOLOv26n,
validate each model individually and keep the board on a fresh boot.

> **Gotcha discovered:** `/sys/class/remoteproc/remoteprocN` **numbering is NOT stable
> across boots.** On one boot the C7x (`64800000.dsp`) was `remoteproc3`; on the next it
> was `remoteproc17`. Always resolve the C7x **by name** (`cat …/name` == `64800000.dsp`),
> never by a fixed index. The smoke test does this correctly.

## 5. LED question (user asked)

`/sys/class/leds` on the board:
| LED | trigger | state |
|---|---|---|
| `usr0` | heartbeat | blinking (kernel alive) |
| `usr1` | mmc0 (eMMC) | off |
| **`usr2`** | **cpu** | **lit** ← the "third LED from top" |
| `usr3` | mmc1 (SD) | off/flicker on SD I/O |
| `usr4` | none | off |

The third LED (`usr2`) is the **CPU-activity LED** (its `cpu` trigger is set by this
image's device tree). It lights whenever the A72s are busy — normal for the edgeai image
(more services/remoteproc activity than the old minimal image). **Benign, not a fault.**
The `usr0` heartbeat blinking is the real "kernel healthy" indicator.

## 6. What's proven vs. what's left

**Proven on the 11.00 baseline (the whole goal — works):** clean flash + SD-boot, kernel
6.6.58, all 6 compute cores running, `/dev/remoteproc0`, DT overlay applied with no
`bad phdr`, IPC channels incl. endpoint 21, onnxruntime+TIDL EP present, and **end-to-end
TIDL inference on the C7x: 103/103 nodes offloaded, 4.4 ms, exit 0, no size/net-version
errors.** The Phase 4–6 version-skew blocker is gone.

**Remaining items:**
1. **Per-model robustness** — the heavy human-pose yolox model hangs/resets the board.
   Characterize which models are safe; treat each new model as suspect until proven.
2. **The custom model (the real target):** compile the teammate's `best.pt` (YOLOv26n) +
   lane model **on x86** with the **11.00-matching tidl-tools** (`~/edgeai-tidl-tools`),
   not on the board, then push artifacts + the Python/MQTT app and run the ADAS pipeline.
   Validate it doesn't trip the heavy-model instability above.
3. **USB stability under load** — heavy TIDL runs can drop the board off USB; power-cycle
   (hold BOOT) to recover. For long ADAS runs, prefer wired `eth0`/SSH over the USB gadget.

## 7. Reconnect cheatsheet (current board)

```bash
IFACE=enxaabbcc000001     # after first reset; may be usb0 on the very first plug
sudo ip link set $IFACE up; sudo ip addr add 192.168.7.1/24 dev $IFACE 2>/dev/null
sudo sysctl -qw net.ipv4.conf.$IFACE.rp_filter=0
SO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
sshpass -p '' ssh $SO root@fe80::a8bb:ccff:fe00:2%$IFACE   # empty password
# board IPv4 (optional): on board → ip addr add 192.168.7.2/24 dev usb0
```
- **If board drops off USB after a TIDL run:** power-cycle (hold BOOT while plugging
  USB-C). Reset is expected after heavy TIDL/IPC ops on this image.
- **Never run `vx_app_arm_remote_log.out` concurrently with a TIDL run** — crashes USB.
