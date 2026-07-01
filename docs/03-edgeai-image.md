# 03 — EdgeAI image (`tisdk-edgeai-image`, brand = `edgeai`)

This is the **real ADAS target**: the full TI SDK EdgeAI image with the C7x/MMA
firmware stack and Qt6/Weston, on top of the same custom layer. It is what actually
runs the on-device inference described in docs 05–08.

## What changes vs. the minimal image
The two images share one tree; `ARAGO_BRAND` selects between them (see
[`config/README.md`](../config/README.md)). For `edgeai`:
- **Graphics kept:** `wayland + opengl` stay in `DISTRO_FEATURES` so the TI Rogue GPU
  driver provides `virtual/egl` + `virtual/libgles2` for Qt6/Weston.
- **EdgeAI uEnv:** `dorprocboot=1` + the `k3-j721e-edgeai-apps` overlay, which loads
  the C71x/MMA firmware at boot (see [04 — C7x enablement](04-c7x-enablement.md)).
- **ADAS runtime dep:** `python3-paho-mqtt` added **only** to this image
  (`IMAGE_INSTALL:append:pn-tisdk-edgeai-image`), for the CARLA→MQTT frame feed.
  Everything else the app needs (numpy/opencv/pyyaml/pillow + the onnxruntime TIDL EP)
  is already in the EdgeAI image.

Image customization: [`.../recipes-core/images/tisdk-edgeai-image.bbappend`](../yocto/meta-bbai64-minimal/recipes-core/images/tisdk-edgeai-image.bbappend)

## Build
```bash
cd tisdk
source sources/oe-core/oe-init-build-env build
# set ARAGO_BRAND = "edgeai" in conf/local.conf
bitbake tisdk-edgeai-image
```

> ⚠️ `ARAGO_BRAND` is a shared toggle. You cannot build the minimal and EdgeAI images
> from the same config at once — flip the brand and rebuild.

---

## Complications hit & how they were solved

### 1. Qt6 fails to build: `-fcf-protection=full not supported`
**Symptom:** EdgeAI Qt6 modules fail to configure on aarch64 with
`-fcf-protection=full not supported`.
**Fix:** patch the exported `Qt6Targets.cmake` to change `full` → `none` and
reconfigure. (Control-flow protection is x86-only; the flag leaks into the aarch64
Qt CMake config.)

### 2. Deploy-dir orphan — `do_image_wic: cannot stat '…/Image'`
**Symptom:** `do_image_wic` fails to stat kernel/bootloader artifacts.
**Root cause:** `deploy-ti` was emptied (artifacts deleted) but the `do_deploy` sstate
stamps were still valid, so bitbake wouldn't auto-restore them.
**Fix (sstate is intact; `rm_work` makes these fast):**
```bash
bitbake virtual/kernel virtual/bootloader -c deploy -f    # Image, dtbs, tispl.bin, u-boot.img
bitbake mc:k3r5:u-boot-bb.org -c deploy -f                # tiboot3.bin (from the k3r5 multiconfig!)
bitbake tisdk-edgeai-image
```
`tiboot3.bin` comes from the **k3r5 multiconfig**, not the A72 bootloader — easy to miss.

### 3. Intentional SDK downgrade 11.02 → 11.00 breaks the PR service
The board firmware only accepts a specific TIDL version, which forced building on the
**11.00** SDK (see [05 — TIDL version matching](05-tidl-version-matching.md)). Going
*backwards* in package versions (e.g. openssl 3.2.6 → 3.2.4) makes the PR service raise
fatal "version-going-backwards / would break package feeds" errors at `do_packagedata`.
**Fix:** disable it — `PRSERV_HOST = ""`. We flash full `.wic` images, not incremental
package feeds, so the PR service adds no value.

### 4. Corrupt/truncated source download → `do_unpack` tar EOF
A truncated download surfaces as a `do_unpack` "unexpected EOF in archive". A plain
re-fetch is blocked by the fetch stamp. **Fix:** delete the tarball **and** its `.done`
file, then `bitbake -c fetch -f <recipe>`.

### 5. Host ran out of RAM and disk during the build
This image is heavy enough that a constrained build host exhausts memory and disk
partway through. The swap layering and loop-mounted overflow volume used to complete it
are documented separately in
[09 — host resource constraints](09-build-resource-constraints.md).

## Related
- Host resource workarounds: [`09-build-resource-constraints.md`](09-build-resource-constraints.md)
- Boot/login log for this image: [`raw-logs/EDGEAI_BOOT_LOGIN_LOG.md`](raw-logs/EDGEAI_BOOT_LOGIN_LOG.md)
- Full image requirements: [`raw-logs/YOCTO_IMAGE_REQUIREMENTS.md`](raw-logs/YOCTO_IMAGE_REQUIREMENTS.md)
