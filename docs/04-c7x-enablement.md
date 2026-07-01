# 04 — C7x / DSP enablement

Before any model can run on the accelerator, the C7x-MMA DSP has to actually boot its
RTOS firmware and establish an IPC (rpmsg) channel with Linux. On the stock image this
did **not** work out of the box; this is the sequence of problems and fixes.

## Symptom
The AI cores (C66x / C7x) would not start, or started "running" but never produced an
rpmsg endpoint — so the TIDL runtime on Linux had no accelerator to talk to.

## Root causes & fixes

### 1. `dorprocboot=1` is a no-op in the u-boot-bb.org build
The BeagleBoard.org U-Boot used here ignores `dorprocboot`, so the remote-proc firmware
wasn't being loaded the way the TI docs imply. Firmware loading had to be driven from
the kernel/DT side instead (EdgeAI overlay + memory carveouts below).

### 2. Firmware ↔ device-tree memory-map mismatch
The prebuilt C7x firmware expects its carveout at one physical address
(`0xb2…`) while the kernel device tree reserved a different region (`0xa8…`). With the
regions mismatched the DSP either won't load or faults immediately.
**Fix:** a device-tree carveout that matches the firmware's expected map —
[`.../recipes-kernel/linux/files/k3-j721e-rtos-memory-map.dtsi`](../yocto/meta-bbai64-minimal/recipes-kernel/linux/files/k3-j721e-rtos-memory-map.dtsi),
plus enabling the remoteproc character device
([`remoteproc-cdev.cfg`](../yocto/meta-bbai64-minimal/recipes-kernel/linux/files/remoteproc-cdev.cfg))
and the EdgeAI apps overlay
([`k3-j721e-edgeai-apps.dtso`](../yocto/meta-bbai64-minimal/recipes-kernel/linux/files/k3-j721e-edgeai-apps.dtso)).

### 3. **DSP timer contention** — the subtle one
After the memory map was fixed, the C66/C7x cores booted and reported "running", but
**still produced no rpmsg endpoint**. Root cause: Linux's `omap_timer` driver was
**claiming the main timers that the DSP RTOS needs for its own tick**. With the timers
taken, the RTOS couldn't schedule and never came up on the IPC bus.
**Fix:** reserve `main_timer0`–`main_timer5` for the DSP in the device tree so Linux
leaves them alone. After that, a normal boot brings up the **full IPC mesh** and the
rpmsg endpoint (endpoint 21) the TIDL runtime needs.

## Result
On the EdgeAI image with these fixes, the C7x boots its firmware and Linux sees the
accelerator. Proven end-to-end by running a reference model on it — see
[06 — YOLO compilation](06-yolo-compilation.md) and the proof log
[`raw-logs/board-bringup-test-log.md`](raw-logs/board-bringup-test-log.md)
(regnetx-200mf: 103/103 nodes offloaded to C7x, 4.4 ms, no errors).

## Gotchas for anyone reproducing this
- `remoteproc` node numbering is **not stable** across boots. Find the C7x by name
  (`64800000.dsp`), not by `remoteprocN` index.
- A heavy/oversized model can hang or reset the board via the watchdog — see the size
  thresholds in [05 — TIDL version matching](05-tidl-version-matching.md).

Full investigation: [`raw-logs/C7X_ENABLEMENT_INVESTIGATION.md`](raw-logs/C7X_ENABLEMENT_INVESTIGATION.md).
