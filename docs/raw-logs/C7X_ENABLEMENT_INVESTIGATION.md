# C7x / DSP enablement on BeagleBone AI-64 — on-disk investigation (2026-06-20)

Goal: get the C7x+MMA (and DSP/R5) remote cores running so TIDL offload works
(`YOCTO_IMAGE_REQUIREMENTS.md` §4/§5a). Requested approach: the `dorprocboot=1`
path. This file documents what was investigated, what was found, and the real fix.

> **No boot/config changes were made during this investigation — read-only.**
> The card still boots with the working `dorprocboot=0` explicit-boot `uEnv.txt`,
> and the original edgeai uEnv is preserved on the card as `uEnv.txt.orig-edgeai`.
> Fallback is intact; nothing to revert.

---

## Method
Read the actual U-Boot boot logic out of the built binaries (ground truth), and
compared the C7x firmware's required memory to the device-tree carveouts on the
running board.

```sh
# U-Boot env (the real boot macros), from the deploy artifact:
strings -n 6 build/deploy-ti/images/beaglebone-ai64/u-boot.img | grep -iE '^(bootcmd|envboot|bootcmd_ti_mmc|boot_rprocs|dorprocboot|get_kern_mmc|get_fdt_mmc|get_overlay_mmc|bootdir|bootpart)='
# Firmware load segments vs DTB carveouts, on the board:
readelf -l /lib/firmware/j7-c71_0-fw            # PT_LOAD physical addresses
cat /proc/device-tree/reserved-memory/*/reg     # reserved regions
```

---

## Findings

### 1. Our explicit `uenvcmd` skips remote-core boot (by design)
`bootcmd = run ... ; run envboot ; bootflow scan -lb ; ...`
`envboot = ... if test -n $uenvcmd; then run uenvcmd; fi`
Our card sets `uenvcmd` to load `Image`+DTB and `booti` directly → U-Boot runs it
and boots Linux, **never reaching the remote-core boot step**. So on our card the
`dorprocboot` value is irrelevant.

### 2. `dorprocboot=1` is a NO-OP in this U-Boot build (the key finding)
The TI boot method `bootcmd_ti_mmc` does call `run boot_rprocs`, **but**:
- `boot_rprocs=` is **not defined anywhere** in `u-boot.img` (only *referenced*).
- `dorprocboot=` is **not in the U-Boot env at all**.

This U-Boot is **beaglebone.org's `u-boot-bb.org`**, which (unlike the TI EVM
U-Boot) **does not boot the main-domain remote cores**. So setting `dorprocboot=1`
in `uEnv.txt` does nothing here — *the requested dorprocboot path does not exist in
this bootloader.* The cores are meant to be started by **Linux remoteproc** instead
(they enumerate as `offline` with a `firmware-name`, i.e. "Linux loads" mode).

### 3. Linux remoteproc load fails on a firmware↔device-tree memory mismatch
Starting the C7x from Linux (`echo start > /sys/class/remoteproc/remoteproc2/state`)
fails: `remoteproc2: bad phdr da 0xb2100000 ... Failed to load program segments: -22`.

Why — the firmware and the DTB disagree on the C7x memory location:

| C7x firmware (`j7-c71_0-fw`) PT_LOAD | DTB reserved-memory (`c71-memory`) |
|---|---|
| `0xb2100000` … `~0xb2f80000` (~14 MB) | `0xa8100000` (15 MB) |

The firmware is linked for the **standard vision_apps/EVM memory map** (`0xb2…`),
but the **BeagleBone AI-64 kernel DTB** (`k3-j721e-beagleboneai64.dtb`) reserves the
C7x region at `0xa8…`. The kernel refuses to load firmware segments into memory the
DTB hasn't reserved for that core → boot fails. (Same class of mismatch for the C66
DSPs, which wanted `0xa8100000`.)

### 4. The edgeai overlay that would fix this doesn't exist for J721E here
`k3-j721e-edgeai-apps.dtbo` is **not built, not deployed, not in the kernel sources,
and not in the BBAI-64 device-tree list**. TI only ships `…-edgeai-apps.dtbo` for
`j721s2`/`j722s`; the reference `j721e` edgeai uEnv uses `dorprocboot=1` with **no**
overlay — i.e. it relies on the **EVM** U-Boot booting the cores, which our
beagle U-Boot does not do.

### 5. Bonus: file-layout mismatch for the TI bootflow
Even if we used the TI `ti_mmc` bootflow, it loads `${bootdir}/${name_kern}` =
`/boot/Image` and `${bootdir}/dtb/${fdtfile}` — i.e. a `/boot` and `/boot/dtb/`
layout. Our wic places `Image` at the FAT-partition root. So the TI bootflow would
not find our kernel without restructuring too.

---

## Conclusion
**Getting the C7x running on this BeagleBone AI-64 image is a BSP task, not a config
flip.** The `dorprocboot=1` path is a dead end in `u-boot-bb.org`. The real blocker
is that the **vision_apps remote-core firmware in the image (EVM memory map, `0xb2…`)
does not match the BeagleBone AI-64 kernel device tree (`0xa8…`).** They must be made
to agree.

Everything else in `YOCTO_IMAGE_REQUIREMENTS.md` is satisfied (TIDLExecutionProvider,
runtime, deps, RAM/storage) — this memory-map alignment is the last, hard piece.

---

## Options to actually fix it (pick with the team)

**A. Align the kernel device tree to the firmware (recommended, self-contained).**
Add the vision_apps reserved-memory regions (`0xb2…` C7x, and the matching C66/R5/
DDR-heap regions) to the BeagleBone AI-64 DT and point each remoteproc node's
`memory-region` at them, so Linux remoteproc can load the stock firmware. Implement
as a `.dtsi`/overlay patch in a kernel `.bbappend` in `meta-bbai64-minimal`. Needs the
**full** vision_apps J721E memory map (from TI's PSDK `j721e` linker/RM config), not
just the C7x slice. This is the closest to how TI's EVM DT is built.

**B. Use TI's BeagleBone AI-64 edgeai reference DT + firmware as the base.**
Instead of patching, adopt TI's known-good BBAI-64 edgeai device tree + matching
firmware set (the combination TI ships on the official BBAI-64 Edge AI image) so DT
and firmware agree by construction. Lowest risk of a wrong memory map.

**C. Rebuild the remote-core firmware for the beagle memory map.**
Recompile vision_apps/TIDL firmware against the beagle DT's `0xa8…` map. Heaviest
option; only if A/B aren't viable.

### Strongly recommended regardless of option: a serial console
Bring-up of remote cores is iterative and the BBAI-64 has **no on-board serial**, so
every blind reboot is a slow, dark guess. A 3.3 V USB-TTL adapter on the debug header
lets us watch SPL/U-Boot/`remoteproc` messages live and iterate quickly. This is the
single biggest accelerator for finishing C7x enablement.

---

## State after this investigation
- Boot config: **unchanged** (still `dorprocboot=0` explicit-boot — boots reliably).
- Fallback `uEnv.txt.orig-edgeai` present on the card.
- Board reachable: `ssh root@192.168.7.2`.
- C7x/DSP/main-R5: `offline` (not running) — pending the memory-map fix above.

---

## Option A — DRAFTED (2026-06-20)

### Exact target map (extracted from firmware ELF PT_LOAD on the board)
| core | firmware needs | beagle DT had | corrected to |
|---|---|---|---|
| main R5F ×3 | 0xa0…0xa6 | 0xa0…0xa6 | unchanged (already matches) |
| C66_0 | 0xa8100000 (4.9 MB) | 0xa6100000 | **0xa8100000** |
| C66_1 | 0xa9100000 (4.9 MB) | 0xa7100000 | **0xa9100000** |
| C7x (C71) | 0xb2100000 (14.4 MB) | 0xa8100000 | **0xb2100000** (15 MB region) |

Only reserved-memory regions move; `c66-dma-memory`/`c71-dma-memory` (vring pools,
1 MB) move with their `-memory` pair. The remoteproc nodes reference these by
phandle/label (`c66_0_memory_region`, `c71_0_memory_region`, …) so the
`memory-region` wiring follows automatically. No overlaps after the move
(c66_0=0xa8, c66_1=0xa9, ipc=0xaa, c7x=0xb2).

### Files created
- **`sources/meta-bbai64-minimal/recipes-kernel/linux/linux-bb.org_%.bbappend`**
  — `do_configure:prepend` sed-relocates the carveouts in
  `k3-j721e-beagleboneai64.dts`, with a `bbfatal` guard if the dts format
  differs. Permanent fix; rebuild the kernel to bake it in. **Touches only the
  kernel DT — U-Boot / uEnv / dorprocboot=0 are untouched (fallback intact).**
- **`minimal_image/k3-j721e-beagleboneai64-c7x.dtb`** — a prebuilt corrected DTB
  (decompiled base DTB + relocations + recompiled) for **fast validation without a
  kernel rebuild**.

### Fast test path (no rebuild) — validate before committing the build
1. Card in PC reader → mount boot partition → **back up** the current DTB, then
   `cp minimal_image/k3-j721e-beagleboneai64-c7x.dtb  <boot>/k3-j721e-beagleboneai64.dtb`
   (uEnv already loads `k3-j721e-beagleboneai64.dtb`; dorprocboot stays 0).
2. Boot, then over SSH start the cores from Linux:
   `for n in 4 5 0 1 2; do echo start > /sys/class/remoteproc/remoteproc$n/state; done`
   `cat /sys/class/remoteproc/remoteproc*/state`   → expect `running` (esp. remoteproc2 = C7x).
   `dmesg | grep -iE 'remoteproc|rproc|c71|c66'`   → no more `bad phdr`.
3. If cores come up: make it permanent via the `.bbappend` (rebuild kernel) and,
   if you want auto-start at boot, add a small service or set the cores’ DT to
   auto-boot. To revert at any point: restore the backed-up DTB.

### Open risk (to verify during the test)
The C7x VDEV/vring (rpmsg/IPC) region is `ipc-memories@aa000000`; if the firmware
expects the IPC region elsewhere, the cores may boot but rpmsg may not link. The
fast test will show this in `dmesg` (`virtio_rpmsg`/`rproc` errors) without risking
the A72 boot. Iterate over SSH.
