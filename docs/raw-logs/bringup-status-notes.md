# BBAI-64 EdgeAI bring-up — status notes (updated 2026-06-25)

Current bring-up status and next steps. Companion docs: `EDGEAI_BOOT_LOGIN_LOG.md`
(flash/connect/login detail), `C7X_ENABLEMENT_INVESTIGATION.md` (DSP enablement),
`YOCTO_IMAGE_REQUIREMENTS.md` (target requirements from the ML team).

> **START HERE (Phase 8 plan): the 11.00-baseline edgeai image is BUILT and
> ready to flash.** Next session = **flash → login → run all TIDL/C7x tests on the
> new image.** Jump to the "Phase 7" section immediately below; everything under
> "Phase 6" and older is PRE-11.00-baseline history kept for reference only
> (the arm-tidl 11.01.06 pin and the Option-1 firmware-blob path described there
> were SUPERSEDED by the clean 11.00 rebaseline).

---

## Phase 7 (2026-06-25): 11.00 baseline image BUILT — ready to flash & test

### State: DONE — a complete `tisdk-edgeai-image` exists on the host
- **Artifact:** `build/deploy-ti/images/beaglebone-ai64/tisdk-edgeai-image-beaglebone-ai64.rootfs-20260624214902.wic.xz`
  (~1.05 GB) + matching `.wic.bmap`. Symlink `…rootfs.wic.xz` points at it.
- This is the **Option B clean 11.00 baseline** (replaces the 11.01/11.02-skew stack):
  - meta-edgeai 11.00.00.08, meta-ti/arago 11.00.10, kernel **linux-bb.org 6.6.58**.
  - **arm-tidl 11.01.06 pin REMOVED** (it was the version-skew cause). Whole TIDL
    stack is now 11.00-consistent.
  - **Model pinned `11_00_04_00`** (TIDL net `0x20250429`, io.bin **94616** = correct
    J721E 1-core size) — proven on real BBAI-64 by the kevinacahalan layer against the
    SAME stock firmware (net `0x20250437`; the check tolerates the 2025-04 window).
  - **Kernel DT overlay `k3-j721e-edgeai-apps.dtbo`** (in deploy) + **`remoteproc-cdev.cfg`**
    → gives `/dev/remoteproc0` (the dma_buf-translation node we never had before) and
    R5F split mode + the TI RTOS memory map.
  - **SD-boot uEnv.txt baked in** (`bootpart=1:2`, `uenvcmd=run bootcmd_ti_mmc`) so the
    board boots the SD, not eMMC — no more hand-patching the card.
  - `sysfw.itb` fix, `usb-gadget-net` (pinned MAC → `enxaabbcc000001` / board
    `192.168.7.2`), and `python3-paho-mqtt` all present.
  - Stock C7x firmware kept (`ti-edgeai-firmware.bbappend.disabled`); NO gated blob needed.

### What this phase actually did (housekeeping, not a rebuild)
1. **Freed ~15 GB on root** (`/dev/sda5` was 100% full → would HALT the build). Deleted
   only build junk/backups/dup ISOs/installers + `snap` + `crosstool-ng`/`x-tools`.
   **Untouched:** sstate-cache (41 GB), downloads (42 GB), `edgeai-tidl-tools` (needed on
   x86 to compile `best.pt`), the `yocto_tmp.img` loop TMPDIR. Root now ~12–17 GB free.
2. **Fixed a stale-pseudo build error:** a re-run of the build hit
   `qtdeclarative do_package: inode mismatch` (stale fakeroot DB from the earlier
   interrupted build). Fix = `bitbake -c clean qtdeclarative`. **Remember this fix** if
   any recipe throws `inode mismatch` / pseudo abort: `bitbake -c clean <recipe>`.
3. The image was already finished by the user (stamp 20260624214902) so the re-run was
   redundant and was stopped. **No further bitbake needed before flashing.**

### Next session — exact plan (flash → login → test)

**A. Flash the new image to the SD card** (identify the device with `lsblk` FIRST —
last session it was `/dev/sdb`; do NOT assume):
```bash
lsblk            # confirm the card node (e.g. /dev/sdb) — NOT the system disk!
/home/mohamedkhalid/minimal_image/flash.sh /dev/sdX
#   (flash.sh uses bmaptool with the .wic.bmap; or:
#    sudo bmaptool copy --bmap …rootfs.wic.bmap …rootfs.wic.xz /dev/sdX )
```

**B. Boot + login** (SD-boot uEnv is baked in now — should boot SD without holding BOOT;
if it boots eMMC, hold the **BOOT** button while powering):
```bash
/home/mohamedkhalid/minimal_image/board-login.sh        # configures host+board, opens shell
#   or: /home/mohamedkhalid/minimal_image/connect-bbai64.sh && ssh root@192.168.7.2
#   IPv6 rescue if IPv4 down:
#   IFACE=$(ip -br link | awk '/enx[0-9a-f]{12}/{print $1}' | head -1)
#   ping6 ff02::1%$IFACE ; ssh root@fe80::a8bb:ccff:fe00:2%$IFACE
```

**C. Run ALL the tests on the new image** (the point of Phase 8). Suggested order —
each step gates the next:
1. **Boot/identity sanity:** `uname -r` (expect `6.6.58…`), `cat /etc/os-release`,
   `lsusb` on host shows `0525:a4a2`, `ip -br addr`.
2. **remoteproc-cdev present (NEW):** `ls -l /dev/remoteproc*` — expect `/dev/remoteproc0`
   to now exist (it never did on the old stack). `for d in /sys/class/remoteproc/remoteproc*;
   do echo "$(cat $d/name)=$(cat $d/state)"; done` — all cores `running`.
3. **DT overlay applied:** confirm `k3-j721e-edgeai-apps.dtbo` loaded (R5F split mode,
   TI RTOS memory map). `dmesg | grep -iE 'remoteproc|rpmsg|reserved-memory'` — no
   carveout/`bad phdr` errors.
4. **IPC mesh / DSP:** `ls /sys/bus/rpmsg/devices/`, look for the rpmsg endpoint(s)
   (historically endpoint 21); `dmesg | grep -i 'rpmsg_chrdev'`; no timer-contention
   stalls (the overlay should handle it).
5. **TIDL on C7x (the key test):** model zoo at `/opt/model_zoo` (11_00_04_00 set,
   onnxrt cl-6360 regnetx-200mf). Run the on-board smoke test
   (`tidl_smoke_test.py` — copy from `minimal_image/` if not on the card):
   `python3 tidl_smoke_test.py 2>&1 | grep -iE 'Offloaded|Network version|cmd_status|inference OK|NULL'`.
   **EXPECT (the whole goal):** `Offloaded Nodes > 0`, NO "Config file size does not
   match" (io 94616 ✓), NO `cmd_status -1` net-version reject (0x20250429 in the 2025-04
   firmware window ✓), inference OK, board does NOT crash off USB.
6. **If 5 passes → the custom model:** the teammate's `best.pt` (YOLOv26n) + lane model
   must be **compiled on x86** with the **11.00-matching tidl-tools** (net must land in
   the firmware window) using `~/edgeai-tidl-tools` — NOT on the board. Then push the
   compiled artifacts + the Python/MQTT app and run the real ADAS pipeline on C7x+MMA.

### If a flash/boot/TIDL problem appears
- **Board "dead" / PWR-only:** almost always the SD-boot path or `sysfw.itb` — but both
  are baked in now; first re-seat the card and verify it's actually in the BOARD (not the
  laptop reader). Check host `lsusb`/`dmesg` before assuming a board fault.
- **TIDL still rejects the net version** (`cmd_status -1`): the 11.00 model/firmware
  window theory was wrong → fall back to also dropping arm-tidl/vision-apps fully to the
  exact kevinacahalan refs, OR source the matching gated firmware (old Phase 5 path).
- **`inode mismatch` on any recipe during a rebuild:** `bitbake -c clean <recipe>`.

---

## Phase 6 (2026-06-21): public-artifact paths exhausted; 10_01_00 experiment staged

Aborted the gated TI-portal download (Option 1's firmware) and the 11.02 move
(Option 2) and the E2E ticket (Option 3) per direction. Spent this phase proving,
from public/buildable sources only, whether ANY model can match the firmware.

### Findings (all verified offline this phase)
- **The firmware's expected TIDL net version is `0x20250437`** — confirmed via the
  format string `"[%s:%u] Network version - 0x%08X, Expected version - 0x%08X"` in
  the blob and the constant `0x20250437` appearing **27×** (vs **0×** for
  `0x20250630`/`0x20250821`). Identical across psdk_fw tags 11.00.00.01..08,
  11.01.00.01..03, 11.02.x, and `main` HEAD — the j721e/vision_apps_eaik C7x blob is
  byte-identical (13,234,320 B) at every ref. TI froze it and never republished.
- **Published modelzoo net versions (TDA4VM 8bit, verified by downloading + reading
  tidl_net.bin first 4 bytes):**
  | modelzoo | net version | io.bin (J721E) |
  |---|---|---|
  | 09_02_00 | `0x20240401` | 93976 (WRONG size) |
  | 10_00_00 | `0x20240719` | 94616 |
  | 10_01_00 | `0x20241120` | 94616 |
  | *(gap — firmware `0x20250437` lives here, no public model/tools)* | | |
  | 11_00_00 | `0x20250630` | 94616 |
  | 11_01_00 | `0x20250821` | 94616 |
  | 11_02_00 | (newer) | 378392 (4-core, WRONG size) |
  Net versions are chronological. `0x20250437` falls in the **unpublished gap**
  between 10_01_00 and 11_00_00, so **no published model matches**, and since the
  modelzoo is built by the published tidl-tools, **no public tidl-tools can compile
  one to `0x20250437` either** (our `tt1106` emits `0x20250821`).
- **CONCLUSION: the edgeai TIDL path cannot be completed from public artifacts.** The
  matching `0x20250437` firmware/tools exist only inside TI's gated SDK image.

### Staged experiment (the ONLY gate-free thing left to try)
- `edgeai-tidl-models.bbappend` now pins `:edgeai` to **`10_01_00`** (io 94616 passes
  the runtime SIZE gate; net `0x20241120` is OLDER than the firmware's `0x20250437`).
  Firmware is known to REJECT NEWER nets; UNTESTED whether it accepts older. If the
  check is "reject if newer" (not strict-equality), this works with the stock
  buildable firmware and NO gated download. TIDL checks are usually strict-equality,
  so it may still `cmd_status -1` — one reflash decides it.
- `ti-edgeai-firmware.bbappend` → **renamed `.disabled`** so the build uses the stock
  firmware (`0x20250437`). Rename back only if the gated `0x20250821` blob is obtained.
- 10_01_00 `--recommended` onnxrt classification model is **cl-6360 (regnetx-200mf)**,
  NOT cl-6090/mobilenet. Point the smoke test at that dir under `/opt/model_zoo`.

### ⚠️ CRITICAL BUG in the Option-1 firmware tooling (fix before ever reviving it)
Both `ti-edgeai-firmware-get-c7x.sh` and `ti-edgeai-firmware.bbappend.disabled` verify
the firmware by reading its **first 4 bytes** and requiring `21 08 25 20`
(`0x20250821`). **This is wrong.** `vx_app_rtos_linux_c7x_1.out` is an **ELF**: its
first 4 bytes are the ELF magic **`7f 45 4c 46`**, never the net version. That guard
would `bbfatal` on EVERY real firmware blob — including the correct gated one — a
massive false-negative.
- The net version is **NOT at offset 0**. It is an internal constant inside the blob
  (the `0x20250437` value occurs 27× in the current blob; the format string
  `"Network version - 0x%08X, Expected version - 0x%08X"` is the anchor).
- **Correct verification**: search the blob for the little-endian net-version pattern,
  e.g. `grep -o -a -P '\x21\x08\x25\x20' fw.out | wc -l` must be > 0 (expect ~27,
  matching the count of the value it replaces), AND confirm `0x20250437` is GONE.
  Do NOT use `od -A n -t x1 -N 4`. Fix both files before reusing the gated path.

---

## Phase 5 (2026-06-21): Option 1 firmware bbappend + DT fixes BAKED & PROVEN

Implemented the recipe-side fixes so a fresh build reproduces the validated card
state. Two deliverables, both done; one user action remains (supply the firmware blob).

### A. C7x firmware override — Option 1 (Firmware Surgical Strike)
Replaces ONLY the C7x blob with the version-matched 11.01.06 firmware (TIDL net
**0x20250821**) that matches arm-tidl 11.01.06 + the 11_01_00 models.
- **Correction to the original ask**: the target net version is **0x20250821**, NOT
  0x20250437. `0x20250437` is the *current stale/broken* blob; `0x20250821` is the
  11.01.06 one the models need. (The request had them swapped.)
- **Mechanism = `file://` overlay, not SRCREV.** Re-confirmed: psdk_fw.git serves
  0x20250437 at every ref, so no SRCREV fetches 0x20250821. The matching blob exists
  only inside TI's full Processor SDK Linux EdgeAI 11.01 image. So we overlay a blob
  extracted from that SDK; the base recipe re-signs it (same TI_SECURE_DEV_PKG keys)
  and the update-alternatives wiring (`j7-c71_0-fw`) is untouched → no new secure-boot
  risk.
- **Files written:**
  - `meta-bbai64-minimal/recipes-tisdk/ti-psdk-rtos/ti-edgeai-firmware.bbappend` —
    `SRC_URI:append:edgeai = file://vx_app_rtos_linux_c7x_1.out`; `do_install:prepend`
    copies the overlay over the git blob BEFORE signing, with a **build-time guard**
    that bbfatal's unless the file exists AND its first 4 bytes = `21 08 25 20`
    (0x20250821). A wrong/stale blob cannot slip through.
  - `meta-bbai64-minimal/recipes-tisdk/ti-psdk-rtos/ti-edgeai-firmware-get-c7x.sh` —
    extracts `vision_apps_eaik/vx_app_rtos_linux_c7x_1.out` from a TI EdgeAI SDK 11.01
    archive (.wic.xz / rootfs .tar.xz / unpacked installer) and **verifies** net
    0x20250821 before staging it into `files/`.
- **USER ACTION (only remaining blocker):** download the TI EdgeAI SDK 11.01 artifact
  (https://www.ti.com/tool/PROCESSOR-SDK-J721E → Edge AI; or
  https://software-dl.ti.com/jacinto7/esd/processor-sdk-linux-edgeai/TDA4VM/ , 11.01.xx),
  then run the get-c7x.sh script pointed at it. It stages `files/vx_app_rtos_linux_c7x_1.out`.

### B. DT fixes baked into the kernel bbappend — PROVEN content-identical to card
All Phase 2-4 DT fixes (which previously lived ONLY on card DTB `f1771a17`) are now
in the recipe, derived **by diffing the stock built DTB against the on-card f1771a17**.
- **Files written:**
  - `meta-bbai64-minimal/recipes-kernel/linux/files/bbai64-vision-fixups.dtsi` — a DT
    fragment using full-path overrides (`&{/path}`, no label guessing): timers
    `2400000`–`2450000` reserved; `r5fss@5c00000` cluster-mode 0x01→0x00 (split);
    `r5f@5d00000` (mcu2_1) memory-region re-pointed to the a4 regions; `r5fss@5e00000`
    disabled + its cores' memory-region deleted; `r5f-memory@a2100000`/`@a4100000`
    resized to 0x1f00000 (31 MB) with a3/a5 nodes deleted; reserved-memory adds
    `vision-apps-shared-a@ac000000` (64M), `-b@b0000000` (32M),
    `vision-apps-ddr-{mcu2-0@d9,mcu2-1@da,c6x-1@dc,c6x-2@e0}000000` (16M each, no-map),
    and `vision_apps_shared-memories` dma-heap-carveout @ 0xb3000000 (172M).
  - `meta-bbai64-minimal/recipes-kernel/linux/linux-bb.org_%.bbappend` — appends the
    fragment in `do_configure:prepend` AFTER the existing C66/C71 carveout sed; idempotent,
    with a landing guard.
- **VALIDATION (done this phase, no on-board retest needed):** simulated the bake
  (stock decompiled dts + fragment → recompile → dtb), then compared to the card DTB
  with `dtc -O dts -s` (sorted, order-independent, phandles stripped):
  **IDENTICAL.** The baked DTB == validated card `f1771a17` content-exactly.
- Note: the "C7x 256M @ 0x117000000" from Phase 4 notes was NOT reserved — that
  address is in a non-RAM hole (RAM banks are 0x80000000–0x100000000 and
  0x880000000–0x900000000), so reserving it is meaningless. The real crash-fix heaps
  (d9/da/dc/e0, all in bank 0) ARE reserved.

### Exact commands to run

**1. Get + stage the firmware blob** (download the SDK 11.01 artifact first — confirm the
real filename on the page, it changes per point release):
```bash
# TI page: https://www.ti.com/tool/PROCESSOR-SDK-J721E  -> EDGE AI
# CDN dir: https://software-dl.ti.com/jacinto7/esd/processor-sdk-linux-edgeai/TDA4VM/  (pick 11.01.xx)
# Then point the script at the .wic.xz / rootfs .tar.xz / unpacked installer:
/home/mohamedkhalid/tisdk/sources/meta-bbai64-minimal/recipes-tisdk/ti-psdk-rtos/ti-edgeai-firmware-get-c7x.sh \
    /path/to/<edgeai-sdk-11.01-artifact>
# Must end with: [OK] staged verified firmware ... net 0x20250821
```
The script refuses to stage anything whose net version isn't `0x20250821`. If it can't find
a matching blob in that SDK, the SDK isn't 11.01.06 — get the right release; do not bypass.

**2. DT bake — nothing to run.** Already done + proven: the baked DTB equals the
card-validated `f1771a17` content-exactly (`dtc -s` sorted diff = identical). No on-board
re-test needed.

**3. Rebuild** (you run bitbake — I don't):
```bash
cd /home/mohamedkhalid/tisdk
source sources/oe-core/oe-init-build-env build
# force re-derive the affected recipes:
bitbake -c cleansstate ti-edgeai-firmware virtual/kernel
bitbake tisdk-edgeai-image
```

**4. Sanity-check the built DTB matches the validated one** (optional, fast):
```bash
dtc -I dtb -O dts -s build/deploy-ti/images/beaglebone-ai64/k3-j721e-beagleboneai64.dtb 2>/dev/null \
  | grep -vE 'phandle|timestamp' > /tmp/built.dts
dtc -I dtb -O dts -s /tmp/card_f1771a17.dtb 2>/dev/null \
  | grep -vE 'phandle|timestamp' > /tmp/good.dts
diff /tmp/built.dts /tmp/good.dts && echo "DTB OK == f1771a17"
```

**Two honest caveats**
- I cannot fully verify the SDK firmware is `0x20250821` until you have the SDK archive —
  but the script + bbappend both hard-gate on it, so a wrong blob fails loud, never silent.
- The firmware step is the only thing left blocking TIDL. Once the blob is staged and the
  image rebuilt + reflashed, the C7x net-version check should pass (size check already
  proven fixed on hardware).

Board is still up (`f1771a17`, uptime ~1h20m).

---

## Phase 4 (2026-06-21): TIDL ROOT CAUSE SOLVED — model/runtime version mismatch

**The "vxCreateContext NULL" was a RED HERRING.** Traced the real failure with
LD_PRELOAD interception + objdump:

- `vxCreateContext()` actually **SUCCEEDS** (returns a valid context).
- The NULL comes later, inside `TIDLRT_create` (in `libvx_tidl_rt.so`), from this
  exact check (decompiled at `0x75aec`, error string at rodata `0x79ed8`):
  ```
  TIDL_RT_OVX: ERROR: Config file size (%d bytes) does not match size of
               sTIDL_IOBufDesc_t (%d bytes)
  TIDL_RT_OVX: ERROR: Map of config object failed
  ```
  The model's `subgraph_0_tidl_io_1.bin` is **378392 bytes**, but the on-board
  runtime expects **94616 bytes** (`0x17198`). Mismatch → config object map fails
  → NULL ref → `Create state function failed. Return value:-1`, **0 nodes offloaded**.

### Root cause: TIDL model artifacts are the WRONG SDK VERSION for this board
- `sizeof(sTIDL_IOBufDesc_t)` is set by `TIDL_MAX_NUM_CORES` in `itidl_io.h`:
  - J721E/TDA4VM (1 C7x core) → **94616 bytes** ✅ what this board's runtime/firmware use
  - J784S4/AM69A (4 cores)   → **378392 bytes** ← what the installed models are
  - J722S (2 cores)          → 189208 bytes
  (Confirmed by compiling `sizeof` on-board with `-DSOC_J721E` vs `-DSOC_J784S4`.)
- The board runs the **11.01** TIDL stack end-to-end:
  - `ti-vision-apps` (edgeai brand) → `REL.PSDK.ANALYTICS.NONSAFETY.11.01.00.03`
    (libtivision_apps.so.11.1.0 + C7x firmware)
  - `ti-tidl.bbappend` already pins `arm-tidl` → `REL.TIDL.11.01.06.00`
    (SRCREV `6f8008a8`) → `libvx_tidl_rt.so` expects **94616**.
- BUT `edgeai-tidl-models.bb` downloads with `EDGEAI_SDK_VERSION=11_02_00` →
  11.02 artifacts compiled with TIDL tools 11.02.02 → **378392-byte io.bin**.
  → model (11.02) ≠ runtime+firmware (11.01).

### THE FIX (proven)
- Downloaded the matching **11_01_00** TDA4VM model from TI's modelzoo:
  `…/modelzoo/11_01_00/modelartifacts/TDA4VM/8bits/cl-6090_…mobilenet_v2_tv_onnx.tar.gz`
  → its `io.bin` is **94616 bytes**, compiled with **TIDL tools 11_01_06_00**
  (exactly matching the pinned arm-tidl 11.01.06). **Version-aligned.**
- **Permanent recipe fix WRITTEN**:
  `meta-bbai64-minimal/recipes-tisdk/edgeai-components/edgeai-tidl-models.bbappend`
  overrides `do_fetch` to use `EDGEAI_SDK_VERSION=11_01_00` for the edgeai brand.
- **On-device compilation is NOT possible** — `tidl_model_import_onnx.so` (the
  x86-only TIDL compiler) is absent; `TIDLCompilationProvider` silently falls back
  to CPU (0 nodes offloaded). Models must be prebuilt (downloaded) or compiled on x86.

### Phase 4 also: reserved the firmware DDR heaps (prevents crashes)
Captured the full firmware DDR map from `vx_app_arm_remote_log.out` "Created heap"
lines: MCU2_0 `0xd9000000` (16M), MCU2_1 `0xda000000` (16M), C6x_1 `0xdc000000`
(16M), C6x_2 `0xe0000000` (16M), C7x `0x117000000` (256M). The `0xd9–0xe0`
regions were live Linux **System RAM** (`b3000000-ffffffff`) → firmware writes
corrupted kernel memory (cause of the repeated board crashes). Added 4 `no-map`
reserved-memory nodes via fdtput; confirmed `d9000000-daffffff`, `dc000000-dcffffff`,
`e0000000-e0ffffff` now `reserved` in `/proc/iomem`. **On-card DTB md5 = `f1771a17`**
(was `b5ee5091`); backup `…dtb.premap`. (This did NOT by itself fix vxCreateContext —
the model version was the real blocker — but it stops the corruption/crashes.)

### IMMEDIATE NEXT STEP (Phase 5 — do this first, ~2 min)
The 11.01 model is already packaged on the host at `/tmp/m1101_pkg.tar.gz` (and the
board copy may be at `/root/model_1101/`). After power-cycling the board:
```bash
# host: reconnect (USB is flaky — helper auto-recovers via IPv6 link-local)
/home/mohamedkhalid/minimal_image/rc.sh 'uptime'
# push the matched model if not already there, then run it:
SO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
sshpass -p '' scp $SO /tmp/m1101_pkg.tar.gz "root@[fe80::a8bb:ccff:fe00:2%enxaabbcc000001]:/root/model_1101/"
/home/mohamedkhalid/minimal_image/rc.sh 'cd /root/model_1101 && tar xf m1101_pkg.tar.gz &&
  python3 /root/tidl_smoke_test.py /root/model_1101 2>&1 | grep -iE "Offloaded|inference OK|RESULT|ZONE_ERROR"'
# EXPECT: "Offloaded Nodes" > 0 AND "inference OK" with NO vxGetStatus NULL.
```
If that prints inference OK with nodes offloaded → **TIDL on C7x is fully working.**

### Phase 4 UPDATE 2 — the 11.01 model got further, exposing a SECOND skew (firmware)
After deploying the matched 11.01 model (io.bin 94616, size check now PASSES), TIDL
got **much further**: A72 creates the OpenVX graph + TIDL node and sends NODE_CREATE
to the C7x. New error (different, deeper):
```
VX_ZONE_ERROR: [ownContextSendCmd:1001] Command ack message returned failure cmd_status: -1
VX_ZONE_ERROR: [ownNodeKernelInit:704] Target kernel, TIVX_CMD_NODE_CREATE failed for node TIDLNode
VX_ZONE_ERROR: kernel com.ti.tidl:1:1 ... failed !!!  ->  Graph verify failed
```
This is a **TIDL network-version check on the C7x firmware**. Firmware string:
`Network version - 0x%08X, Expected version - 0x%08X`.
- **model net.bin version** (first 4 bytes) = **0x20250821** (11.01.06 tools, ~Aug 2025)
- **firmware expected version** = **0x20250437** (found 27× in
  `/usr/lib/firmware/vision_apps_eaik/vx_app_rtos_linux_c7x_1.out`; ~Apr 2025)
- 0x20250821 != 0x20250437 → C7x rejects the network → cmd_status -1.

**The C7x firmware is a PREBUILT BLOB** from `ti-edgeai-firmware.bb`
(`psdk_fw.git` SRCREV `acdb1854`), NOT from vision-apps. Its TIDL net version is
`0x20250437`, which is **OLDER than every published TIDL tool**:
| component | source | net version | io.bin (J721E) |
|---|---|---|---|
| C7x firmware (current) | ti-edgeai-firmware psdk_fw `acdb1854` | **0x20250437** (Apr) | 94616 |
| arm-tidl runtime | ti-tidl.bbappend `6f8008a8` (REL.TIDL.11.01.06.00) | (Aug-era) | 94616 |
| 11_01_00 modelzoo | tidl-tools 11_01_06_00 | 0x20250821 (Aug) | 94616 |
| 11_00_00 modelzoo | tidl-tools 11_00_08_00 | 0x20250630 (Jun) | 94616 |
| 11_02_00 modelzoo (orig) | tidl-tools 11_02_02 | (newer) | **378392** (4-core, wrong) |

**No published model matches the current firmware (0x20250437).** Published
tidl-tools are only 11_00_08_00 (Jun) and 11_01_06_00 (Aug) — both newer.
`psdk_fw.git` tags for the 11.01 line stop at `11.01.00.03`; there is **no 11.01.06
firmware tag**. So the stack as pinned cannot be made consistent with the current
firmware blob.

**=> The real remaining fix is to BUMP THE C7x FIRMWARE** so its net version matches
the runtime + models (0x20250821). The firmware that TI used to build the 11_01_00
modelzoo is reported in the model's run.log as **"C7x Firmware Version 11_01_06_00"**,
so an 11.01.06 firmware blob exists — it just isn't a psdk_fw tag (likely psdk_fw
`main` HEAD, newer than `acdb1854`, or in the TI 11.01.06 EdgeAI SDK image). Next
session: obtain the 11.01.06 `vx_app_rtos_linux_*.out` blobs and either (a) place
the C7x one on the card to test immediately, or (b) bump `ti-edgeai-firmware`
SRCREV via a bbappend and rebuild. (`x86 tidl_model_import_onnx.so` IS available in
`/tmp/tt1106.tar.gz` → `tidl_tools/`, so models can also be compiled on x86 if a
matching-version path is chosen, but the version must equal the firmware's.)

**CONCLUSIVE (checked this phase):** `psdk_fw.git`'s j721e
`vision_apps_eaik/vx_app_rtos_linux_c7x_1.out` is net **0x20250437 at EVERY ref**
tried — `main` HEAD and tag `11.00.00.08` both return the identical 13234320-byte
blob (net 0x20250437). So TI never published a j721e firmware matching the modelzoo
net versions (0x20250630 / 0x20250821) to psdk_fw. The "C7x Firmware Version
11_01_06_00" used to build the modelzoo exists only inside TI's full **Processor SDK
Linux EdgeAI 11.01.06** image — NOT in the psdk_fw git the build fetches.

=> This is a TI artifact-availability gap, not something fixable by re-pinning a
psdk_fw SRCREV. Resolution options for the user (need a decision + rebuild):
  1. **Get the matching firmware from TI's full EdgeAI SDK 11.01.06** (the
     `vx_app_rtos_linux_c7x_1.out` etc. with net 0x20250821), install it via
     ti-edgeai-firmware.bbappend (override do_install to use the SDK blobs), keep
     arm-tidl 11.01.06 + 11_01_00 models. Most direct once the SDK is downloaded.
  2. **Move the whole edgeai TIDL stack to 11.02** (psdk_fw HAS REL.PSDK.ANALYTICS.
     11.02.x firmware tags; tidl-tools 11_02_04_00 + arm-tidl 11.02.04 + 11_02
     modelzoo all exist). Blockers to resolve: vision-apps edgeai is pinned to
     NONSAFETY.11.01.00.03 (no NONSAFETY 11.02 manifest → would need the ANALYTICS
     11.02 vision-apps, and the 11.02 TDA4VM modelzoo ships a 378392/4-core io.bin
     that must be re-checked against an 11.02 j721e runtime).
  3. **TI E2E ticket** about the 11.01 NONSAFETY firmware↔modelzoo version gap.

Downloaded artifacts staged on host: `/tmp/m1101_pkg.tar.gz` (11.01 model, net
0x20250821), `/tmp/m1100/` (11.00 model, net 0x20250630), `/tmp/tt1106.tar.gz`
(x86 tidl-tools 11.01.06). Board copy: `/root/model_1101/`.

### Helper added this phase
`/home/mohamedkhalid/minimal_image/rc.sh '<cmd>'` — robust reconnect+run. Waits
for USB, configures host iface, reaches the board over IPv6 link-local
(`fe80::a8bb:ccff:fe00:2`), best-effort sets board IPv4, runs the command. Use it
for everything (the pinned-MAC iface is `enxaabbcc000001`).
NOTE: running `vx_app_arm_remote_log.out` concurrently with a TIDL run crashes the
board off USB — avoid; read versions statically from the firmware blob instead.

### STILL TO DO (updated Phase 5)
1. **DONE (S5)** — DT fixes baked into the kernel `.bbappend`
   (`bbai64-vision-fixups.dtsi`), proven content-identical to card `f1771a17`.
2. **DONE (S5)** — C7x firmware override recipe written
   (`ti-edgeai-firmware.bbappend`, Option 1). **USER must stage the blob**: run
   `ti-edgeai-firmware-get-c7x.sh <TI-EdgeAI-SDK-11.01-artifact>` to extract+verify
   `vx_app_rtos_linux_c7x_1.out` (net 0x20250821) into `files/`. Until staged, the
   firmware recipe bbfatal's by design.
3. **Rebuild** (USER runs): `bitbake -c cleansstate ti-edgeai-firmware virtual/kernel`
   then `bitbake tisdk-edgeai-image`. Pulls 11_01_00 models + baked DTB + new firmware.
4. **Reflash + run** `python3 /root/tidl_smoke_test.py /root/model_1101` — expect
   Offloaded Nodes > 0, inference OK, no cmd_status -1 (size + net-version + DT all aligned).
5. **python3-paho-mqtt**: in local.conf, image not rebuilt yet (folds into the rebuild above).

---

## TL;DR current state (after Phase 4)

- **Board boots, SSH works**: `ssh root@192.168.7.2` (empty password). Linux
  **6.12.43-ti**, Arago **2025.01**, booted from the SD card.
- **ALL SIX cores RUNNING + full IPC mesh works** (Phase 3). DSP side fully
  healthy: 6-CPU barrier sync, OpenVX targets registered, rpmsg endpoint 21, zero
  firmware errors.
- **TIDL ROOT CAUSE(S) FOUND (Phase 4)** — NOT vxCreateContext (that succeeds).
  TWO stacked version mismatches:
  1. **io-descriptor SIZE** (FIXED): installed models were 11.02 (io.bin 378392,
     4-core layout) vs runtime 94616 (J721E 1-core). Switched to 11.01 models
     (io.bin 94616) → size check passes, TIDL now reaches the C7x. Recipe fix
     written: `edgeai-tidl-models.bbappend` (11_02_00 → 11_01_00).
  2. **TIDL network VERSION** (OPEN): C7x firmware expects net version 0x20250437
     (~Apr 2025, a stale `psdk_fw` blob) but every available model is newer
     (11.01.06→0x20250821, 11.00.08→0x20250630). C7x rejects the net →
     `TIVX_CMD_NODE_CREATE failed, cmd_status -1`. **Fix = bump the C7x firmware
     to 11.01.06** (net 0x20250821) to match runtime+models. See "Phase 4
     UPDATE 2" for the full matrix + how to source the firmware.
- **Firmware DDR heaps now reserved** (Phase 4): added `no-map` nodes for
  `0xd9/0xda/0xdc/0xe0` (were live System RAM → cause of repeated crashes).
  On-card DTB md5 = **`f1771a17`** (backup `…dtb.premap`).
- **Board crashes off USB after heavy TIDL/firmware ops** — power-cycle (hold BOOT
  while plugging USB-C) to recover. Reconnect with `rc.sh` (handles flaky USB).
- **python3-paho-mqtt**: added to `local.conf` but image not rebuilt yet.

---

## Phase 3 (2026-06-21 cont.): IPC mesh SOLVED, TIDL one step away

### What was discovered + fixed (all VALIDATED on hardware)

1. **mcu2_1 split-mode CONFIRMED working.** After reboot with the `c495c82a` DTB,
   `5d00000.r5f` (remoteproc5) registers and runs alongside mcu2_0. All 6 cores up.

2. **ROOT CAUSE of DSP IPC failure = TIMER CONTENTION.** The C66/C7x FreeRTOS
   firmware needs main-domain hardware timers for their scheduler tick. Linux's
   `omap_timer` driver had claimed **all 20 main timers** (`2400000`–`2530000`),
   including the ones the DSP firmware uses (`2400000/2410000/2420000`). Result:
   DSP boots → scheduler can't tick → firmware hangs → shows "running" but never
   announces rpmsg_chrdev. (R5F works because it uses MCU-domain timers Linux
   doesn't touch.) Found via the BeagleBoard forum post
   `bbai64-debian-with-c7x-ti-vision-apps-recipe-patch` + confirmed live.
   - **FIX**: mark `main_timer0`–`main_timer5` (`2400000`–`2450000`) as
     `status = "reserved"` in the DTB so `omap_timer` skips them, leaving them for
     the DSP firmware. Linux timekeeping uses `arch_sys_counter`, so these omap
     timers are non-critical (PWM/spare). **Validated**: with timers reserved +
     normal boot, DSPs announce rpmsg_chrdev at **endpoint 0x15 (21)** — exactly
     what libtivision_apps expects — and `IPC: Init ... Done` with **no** "Unable
     to create TX channels" errors. Boot-order (late-start) does NOT work; the
     barrier sync needs all cores booting together → must be a DT reservation.

3. **OpenVX shared-memory regions were missing from the DT.** Strace of the failing
   TIDL run showed libtivision_apps mmaps fixed physical addresses via `/dev/mem`:
   `0xac000000`(256K)+`0xac040000`(63.75M) = obj-descriptor region [64MB], and
   `0xb0000000`(3.1M)+`0xb0400000`(28M) = shared heap [32MB]. These were **live
   Linux RAM** (`abc00000-b1ffffff : System RAM`), so the OpenVX object descriptors
   landed in kernel memory.
   - **FIX**: added two `no-map` reserved-memory nodes —
     `vision-apps-shared-a@ac000000` (0xac000000, 64MB) and
     `vision-apps-shared-b@b0000000` (0xb0000000, 32MB). **Applied + confirmed
     reserved** (`ac000000-b2ffffff : reserved`). Necessary but did NOT by itself
     fix the `vxCreateContext` NULL.

### The remaining blocker (where Phase 4 should start)

- A72 `vxCreateContext()` returns NULL even though the firmware mesh is perfect.
- **Strongest lead**: firmware MEM logs (via remote log reader) show each core's
  `DDR_LOCAL_MEM` heap at `0xd9000000` (mcu2_0, 16M), `0xda000000` (mcu2_1),
  `0xdc000000` (c6x_1), `0xe0000000` (c6x_2), and C7x 256MB. These are NOT reserved
  (our DT only covers a0–b3). Either they overlap Linux RAM (→ corruption; note the
  board crashed off USB after repeated runs) or the obj-desc/IPC map is still
  incomplete. **Next step: reserve the FULL TI J721E vision_apps memory map**, not
  piecemeal. TI's canonical map defines all DDR_LOCAL/DDR_SHARED/L3 regions; it was
  not found in the kernel DT sources (vision_apps firmware is a prebuilt binary in
  `ti-edgeai-firmware`). May need to extract from TI SDK docs / the EVM RTOS dtbo,
  or reconstruct from the firmware MEM logs (capture ALL "Created heap" lines).
- Possible secondary: TIOVX obj-descriptor ABI — A72 lib is
  `libtivision-apps11.1.0` (pkg `11.02.03-r0_edgeai_15.0`); firmware is
  `vision_apps_eaik` from `ti-edgeai-firmware`. Verify these are the same
  vision_apps version.

### On-card DTB backups (SD = mmcblk1, boot part = `/run/media/boot-mmcblk1p1/`)

- Active DTB `k3-j721e-beagleboneai64.dtb` = md5 `b5ee5091` (timer-reserved +
  obj-desc/heap regions). Backups: `.preshared` (md5 `48e92541`, timer fix only),
  `.pretimer` (md5 `c495c82a`, Phase 2 baseline), plus older `.handbuilt`,
  `.heaponly`, `.nocarveheap`, `.r5fonly`, `.orig-precarveout`.
- Helper scripts staged on board: `/root/dsp_timer_test.sh`, `/root/tidl_smoke_test.py`,
  `/root/tidl_debug.py`. (DSP firmware in `/lib/firmware/j7-*` is in normal names.)

---

## What was accomplished (in order)

### Phase 1 (2026-06-20): boot + C7x enablement

1. **edgeai image wouldn't boot (PWR-LED only, no heartbeat).**
   - **Root cause #1 — missing `sysfw.itb`.** J721E uses *split boot*: the R5 SPL
     loads system firmware from a file named exactly `sysfw.itb`. A prior
     `do_image_wic` workaround (`IMAGE_BOOT_FILES:remove = "sysfw.itb"`) had deleted
     it. **Permanent fix** in `build/conf/local.conf`:
     `IMAGE_BOOT_FILES:append = " sysfw-j721e-gp-evm.itb;sysfw.itb"`.
   - **Root cause #2 — no stage-2 kernel payload.** The wic ships `grub.cfg` but no
     grub binary and no DTB, and the stock edgeai `uEnv.txt` never actually boots.
     Fix: explicit-boot `uEnv.txt` (`dorprocboot=0`, loads Image+DTB+booti) + base
     DTB on card boot partition.
2. **Rebuilt `tisdk-edgeai-image`**, flashed, booted, logged in.
3. **Validated against `YOCTO_IMAGE_REQUIREMENTS.md`:** onnxruntime 1.15.0 with
   `TIDLExecutionProvider` present, numpy/opencv/pyyaml/pillow present,
   torch/ultralytics absent, dma-heap/CMA present, 3.7 GB RAM / 48 GB free.
   Missing: `python3-paho-mqtt`, C7x/DSP cores offline.
4. **C7x enablement — root cause**: firmware linked for TI EVM memory map (C7x @
   `0xb2100000`) but beagle DT reserves C7x at `0xa8100000` → `bad phdr da` → Linux
   remoteproc refuses to load. Same for C66 DSPs.
5. **Built corrected DTB** (carveout relocation: C7x 0xa8→0xb2, C66_1 0xa7→0xa9,
   C66_0 0xa6→0xa8), swapped onto card, rebooted → **C7x + C66s come up running**.
6. **Baked the fix** into `meta-bbai64-minimal/recipes-kernel/linux/linux-bb.org_%.bbappend`
   (sed-based, with bbfatal guard).

### Phase 2 (2026-06-21): TIDL inference + R5F IPC mesh

7. **Ran TIDL smoke test** — onnxruntime compiles model through TIDLExecutionProvider,
   "Offloaded Nodes 103, Total Nodes 103" → full C7x offload **proven**. But inference
   fails at IPC init: vision_apps needs ALL cores (mcu2_0, mcu2_1, c6x_1, c6x_2,
   c7x_1) talking via rpmsg.
8. **DMA heap fix**: added `vision_apps_shared-memories` DT node (compatible =
   "dma-heap-carveout", reg @ 0xb3000000, 172 MB) — creates the
   `/dev/dma_heap/carveout_vision_apps_shared-memories` path that libtivision_apps
   hardcodes. Validated on board.
9. **R5F carveout restructure**: mcu2_0 firmware needs 31 MB DDR (not the 15 MB the
   beagle DT gives). Resized `r5f-memory@a2100000` and `@a4100000` to `0x1f00000`
   (31 MB), repointed mcu2_1's memory-region to a4 regions, removed overlapping a3/a5
   nodes, dropped mcu3 memory-regions (no firmware). **Result: mcu2_0 now runs.**
10. **mcu2_1 still missing**: `main_r5fss0` was in LOCKSTEP mode
    (`ti,cluster-mode = <0x01>`) → only core 0 registers. Built a new DTB with
    `ti,cluster-mode = <0x00>` (split mode) and `main_r5fss1` disabled (no firmware
    available). Also disabled `r5fss@5e00000` (mcu3, was causing -22 probe error).
    **DTB installed on card (md5 `c495c82a`), NOT YET REBOOTED.**
11. **rpmsg_char matching issue identified**: even for running C66/C7x, ti-rpmsg-char
    logs "could not find the matching rpmsg_ctrl device for virtio0/1/2.rpmsg_chrdev".
    Hypothesis: resolves once the full R5F mesh is up (mcu2_0 + mcu2_1). If not, it's
    a vision_apps-lib vs bb.org-kernel rpmsg-topology mismatch requiring deeper work.
12. **User rejected switching to linux-ti-staging** (wouldn't build: 70 beagle DTs
    missing from TI's tree). Agreed to continue with targeted fixes on linux-bb.org.

---

## Immediate next steps (SESSION 4 — start here)

### Step 0: Recover the board (it dropped off USB at end of Phase 3)
Power-cycle: hold **BOOT** while plugging USB-C. Then connect + verify it's the
Phase 3 DTB (`b5ee5091`) and everything came back:
```bash
# Host: find gadget iface + reach board (IPv4 may not be up; IPv6 LL always works)
IFACE=$(ip -br link | awk '/enx[0-9a-f]{12}/{print $1}' | head -1)
ping6 -c2 ff02::1%$IFACE                       # should see fe80::a8bb:ccff:fe00:2
SSH="ssh root@fe80::a8bb:ccff:fe00:2%$IFACE"   # or: ssh root@192.168.7.2 if IPv4 up
# On board — confirm the known-good Phase 3 state:
$SSH 'md5sum /run/media/boot-mmcblk1p1/k3-j721e-beagleboneai64.dtb'   # expect b5ee5091
$SSH 'for d in /sys/class/remoteproc/remoteproc[0-5]; do echo "$(cat $d/name)=$(cat $d/state)"; done'
$SSH 'grep -c rpmsg_chrdev.-1.21 <(ls /sys/bus/rpmsg/devices/)'       # expect 5
$SSH 'grep -iE "ac000000|reserved" /proc/iomem | grep -i reserv'      # ac000000-b2ffffff reserved
```
Expect: all 6 cores running, 5 endpoint-21 channels, `ac000000-b2ffffff : reserved`.
This is the validated baseline — IPC mesh works, only `vxCreateContext` is left.

### Step 1: Solve the `vxCreateContext()` NULL (THE blocker)
Confirm it still reproduces, then attack the memory map (primary theory):
```bash
$SSH 'python3 /root/tidl_smoke_test.py 2>&1 | grep -iE "vxGetStatus|Reference is NULL|IPC: Init|RESULT|inference OK"'
# Capture the FULL firmware DDR map (all "Created heap" lines), not just local heaps:
$SSH '(timeout 20 /opt/vision_apps/vx_app_arm_remote_log.out >/tmp/rl.log 2>&1 &); sleep 2; \
      python3 /root/tidl_smoke_test.py >/dev/null 2>&1; sleep 2; grep -iE "Created heap|MEM:|DDR|L3|SHARED|SCRATCH" /tmp/rl.log'
```
Then **reserve the full TI vision_apps DDR map** in the DTB (firmware heaps at
`0xd9000000`–`0xe1000000`+ are currently unreserved Linux RAM). Add `no-map`
reserved-memory nodes covering every region the firmware "Created heap" lines show,
the same way regions A/B were added (`fdtput -c … ; fdtput -t x … reg … ; fdtput … no-map`).
Back up the DTB first (`cp …dtb …dtb.premap`). Reboot + re-run the TIDL test.
- If still NULL after a complete map: check the TIOVX obj-desc ABI / vision_apps
  version match (A72 `libtivision-apps11.1.0` pkg `11.02.03` vs `vision_apps_eaik`
  firmware). Worst case the prebuilt firmware/library are version-mismatched.

### Step 2: Once TIDL works — bake ALL DT fixes into the .bbappend
`linux-bb.org_%.bbappend` currently has ONLY the C66/C71 carveout sed. Everything
below lives only in the hand-built on-card DTB and must be added (sed or a DT patch):
- DMA heap node (`vision_apps_shared-memories` @ 0xb3000000, 172 MB)
- R5F carveout resize (a2 & a4 → 31 MB, remove a3/a5)
- R5FSS split-mode (`ti,cluster-mode = <0x00>`), mcu3 disabled (`r5fss@5e00000` disabled)
- **NEW (Phase 3): `main_timer0`–`main_timer5` `status = "reserved"`**
- **NEW (Phase 3): reserved-memory `@ac000000` (64MB) + `@b0000000` (32MB), no-map**
- **NEW (Phase 4, once found): the full TI vision_apps DDR memory map**

**CRITICAL: user runs `bitbake` manually — do NOT execute it.**

### Step 3: Rebuild image with python3-paho-mqtt
Already in `local.conf`. Just needs `bitbake tisdk-edgeai-image` (user runs manually).

---

## Key facts / coordinates

| What | Value |
|---|---|
| Board SSH | `ssh root@192.168.7.2` (empty password) |
| Host gadget iface | `enxaabbcc000001` = `192.168.7.1` |
| Board USB MAC | `aa:bb:cc:00:00:02`, IPv6 LL `fe80::a8bb:ccff:fe00:2` |
| Boot method | Hold **BOOT** button while plugging USB-C (forces SD, not eMMC) |
| Login user | `root`, empty password (`debug-tweaks`) — NOT `debian` |
| Kernel | `linux-bb.org` 6.12.43-ti (NOT linux-ti-staging) |
| U-Boot | `u-boot-bb.org` 2025.10 (has NO `dorprocboot`/`boot_rprocs`) |
| TIDL SDK | 11.02.04.00, onnxruntime 1.15.0, libtivision-apps 11.02.03 |
| local.conf | `ARAGO_BRAND="edgeai"`, `MACHINE=beaglebone-ai64` |
| TMPDIR | `${TOPDIR}/yocto-disk/tmp` (loop45 ext4, ~50 GB free) |
| Deploy dir | On `/` (~20 GB free) |
| Custom layer | `sources/meta-bbai64-minimal/` (priority 14) |

### IPv6 link-local rescue (when IPv4 is broken)
```bash
IFACE=$(ip -br link | awk '/enx[0-9a-f]{12}/{print $1}' | head -1)
ping6 ff02::1%$IFACE            # discover board
ssh root@fe80::a8bb:ccff:fe00:2%$IFACE   # login via LL
```

---

## Card boot partition state (as of 2026-06-21, Phase 3)

**SD card = `mmcblk1`; boot partition mounts at `/run/media/boot-mmcblk1p1/`.**
(`mmcblk0` is the eMMC — stock Debian-ish boot, ignore it.)

- **Active DTB**: `k3-j721e-beagleboneai64.dtb` (md5 **`b5ee5091`**) — contains ALL
  Phase 1-3 fixes:
  - C66/C71 carveout relocation (C7x→0xb2, C66_1→0xa9, C66_0→0xa8)
  - R5F carveout resize (a2 & a4 → 31 MB each), a3/a5 nodes removed
  - `vision_apps_shared-memories` dma-heap @ 0xb3000000 (172 MB)
  - `main_r5fss0 ti,cluster-mode = <0x00>` (split mode); `r5fss@5e00000` (mcu3) disabled
  - **Phase 3: `main_timer0`–`5` (`2400000`–`2450000`) `status="reserved"`**
  - **Phase 3: reserved-memory `vision-apps-shared-a@ac000000` (64MB) +
    `vision-apps-shared-b@b0000000` (32MB), both `no-map`**
- **DTB backups on card** (newest first): `.preshared` (md5 `48e92541` = timer fix,
  pre-shared-mem), `.pretimer` (md5 `c495c82a` = Phase 2 baseline), plus older
  `.handbuilt`, `.heaponly`, `.nocarveheap`, `.r5fonly`, `.orig-precarveout`.
  → To roll back the Phase 3 changes: `cp ….dtb.pretimer ….dtb`.
- **Helper scripts staged on board** (`/root/`, survives reboot): `dsp_timer_test.sh`,
  `tidl_smoke_test.py`, `tidl_debug.py`. DSP firmware `/lib/firmware/j7-*` = normal names.
- **uEnv.txt**: explicit-boot, `dorprocboot=0`, loadaddr=0x82000000, fdt_addr_r=0x88000000.
  `uEnv.txt.orig-edgeai` = backup of stock edgeai uEnv (DO NOT LOSE). `sysfw.itb` present.

---

## Build configuration (.bbappend state vs on-card state)

| Fix | In .bbappend? | On card DTB? | Notes |
|---|---|---|---|
| C66/C71 carveout relocation | YES | YES | Validated, sed-based |
| DMA heap (vision_apps_shared-memories) | **YES (S5)** | YES | In `bbai64-vision-fixups.dtsi` |
| R5F carveout resize (a2/a4 → 31 MB) | **YES (S5)** | YES | In fixups dtsi |
| R5FSS split-mode (cluster-mode=0) | **YES (S5)** | YES | In fixups dtsi |
| mcu3 disabled | **YES (S5)** | YES | In fixups dtsi |
| a3/a5 node removal | **YES (S5)** | YES | `/delete-node/` in fixups dtsi |
| **main_timer0-5 reserved (Phase 3)** | **YES (S5)** | YES | In fixups dtsi |
| **obj-desc/heap @ac000000+@b0000000 (Phase 3)** | **YES (S5)** | YES | In fixups dtsi |
| **vision-apps DDR heaps d9/da/dc/e0 (Phase 4)** | **YES (S5)** | YES | In fixups dtsi (no-map) |
| **C7x firmware override → net 0x20250821 (Option 1)** | **YES (S5)** | n/a | `ti-edgeai-firmware.bbappend`; needs the blob staged in `files/` |
| python3-paho-mqtt | In local.conf | N/A | Image not rebuilt yet |

**Baked DT bake VALIDATED**: `dtc -s` sorted diff of the freshly-baked DTB vs card
`f1771a17` = identical (Phase 5). No on-board re-validation needed for the DT part.

---

## Critical gotchas (things that have bitten us)

1. **BBAI-64 has NO onboard USB-serial.** `/dev/ttyUSB*` won't appear without an
   external 3.3V USB-TTL adapter wired to J2. Use the USB network gadget instead.
2. **`g_ether` randomizes MAC every boot** (until pinned). Never hardcode the host
   interface name — auto-detect: `IFACE=$(ip -br link | awk '/enx[0-9a-f]{12}/{print $1}' | head -1)`.
3. **Host IPv4 to gadget needs 4 things**: IP on 192.168.7.0/24, connected route out
   the gadget iface, `rp_filter` not strict, NetworkManager kept off the iface.
   The helper scripts handle all four.
4. **`ARAGO_BRAND = "core"`** in local.conf strips graphics/edgeai uEnv; must be
   `"edgeai"` for tisdk-edgeai-image.
5. **`dorprocboot=1` does NOTHING** in u-boot-bb.org. The variable and the
   `boot_rprocs` macro don't exist in this bootloader. Cores are Linux-loaded only.
6. **J721E split boot**: ROM → tiboot3.bin (R5 SPL) → sysfw.itb → tispl.bin →
   u-boot.img. If `sysfw.itb` is missing, board is completely dead (no LED at all).
7. **Firmware ↔ DT memory map**: TI vision_apps firmware is linked for the EVM memory
   map. The beagle DT uses a different, compact map. Every carveout address must match
   the firmware's PT_LOAD segments or remoteproc refuses to load ("bad phdr").
8. **Host disk is tight (~15-20 GB free).** `INHERIT += "rm_work"` is mandatory.
9. **`lsusb` showing `0525:a4a2` = the board booted.** Check `lsusb` / `dmesg` /
   `ip -br addr` on the host before assuming a board/image fault.

---

## Files in this directory (`minimal_image/`)

| File | Purpose |
|---|---|
| `bringup-status-notes.md` | This file — bring-up status & continuity |
| `CLAUDE.md` | Project instructions for Claude Code |
| `YOCTO_IMAGE_REQUIREMENTS.md` | Target requirements from the ML team |
| `EDGEAI_BOOT_LOGIN_LOG.md` | Detailed flash/connect/login steps with calculations |
| `C7X_ENABLEMENT_INVESTIGATION.md` | Full C7x/DSP investigation trace |
| `BBAI64_MINIMAL_IMAGE_NOTES.md` | Original minimal image bring-up log |
| `tidl_smoke_test.py` | End-to-end TIDL inference test script (run ON the board) |
| `flash.sh` | Flash .wic to SD card |
| `board-login.sh` | Configure host + board USB gadget, open SSH shell |
| `connect-bbai64.sh` | Configure host side of USB gadget networking |

---

## Decision log

| Date | Decision | Why |
|---|---|---|
| 2026-06-20 | Use explicit-boot uEnv.txt (dorprocboot=0) | u-boot-bb.org has no dorprocboot; cores Linux-loaded |
| 2026-06-20 | Carveout relocation via sed in .bbappend | Minimal change; firmware untouched; validated |
| 2026-06-21 | Stay on linux-bb.org, NOT switch to linux-ti-staging | linux-ti-staging won't build (70 beagle DTs missing); targeted fixes work |
| 2026-06-21 | Add dma-heap node (not rebuild firmware) | libtivision_apps hardcodes the heap name; DT node is the fix |
| 2026-06-21 | R5FSS split-mode (cluster-mode=0) | Lockstep only gives 1 R5F core; vision_apps needs mcu2_0 + mcu2_1 |
| 2026-06-21 | Disable mcu3 (r5fss@5e00000) | No firmware available; probe causes -22 error |
