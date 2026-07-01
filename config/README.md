# Build configuration — `local.conf`

`local.conf.example` is the **exact** `build/conf/local.conf` used to build both
images in this project. Copy it to your Yocto `build/conf/local.conf` and adjust
the three host-specific paths at the top.

This file is the closest thing this project has to an FPGA project's *constraint
file*: it pins every non-default decision the build depends on, so the image is
reproducible instead of guessed.

## Host-specific paths to change
```
DL_DIR      = ".../downloads"        # source cache
SSTATE_DIR  = ".../sstate-cache"     # shared build cache (~13 GB)
TMPDIR      = "${TOPDIR}/yocto-disk/tmp"
```

## The one switch that selects the image: `ARAGO_BRAND`

Both target images are produced from the **same tree** by flipping a single
variable. This is the most important thing to understand about the build.

| `ARAGO_BRAND` | Graphics stack | uEnv / accelerator | Builds |
|---|---|---|---|
| `"core"`   | none (wayland/opengl stripped) | clean uEnv, `dorprocboot=0` | `bbai64-minimal-image`, `tisdk-base-image` |
| `"edgeai"` | wayland + opengl + `virtual/libgles2` (Qt6/Weston) | edgeai uEnv, `dorprocboot=1` + C7x/MMA firmware | `tisdk-edgeai-image` (the ADAS target) |

The brand is consumed in `local.conf` by this line, which strips graphics only
for the `core` brand:
```
DISTRO_FEATURES:remove = "x11 vulkan opencl \
    ${@'wayland opengl' if d.getVar('ARAGO_BRAND') == 'core' else ''}"
```

### To build the **minimal** image (bring-up foundation)
```
ARAGO_BRAND = "core"
```
Then: `bitbake bbai64-minimal-image`

### To build the **EdgeAI** image (the real ADAS target — C7x + Qt)
```
ARAGO_BRAND = "edgeai"
```
Then: `bitbake tisdk-edgeai-image`

> ⚠️ `ARAGO_BRAND` is a **shared toggle** — the two images cannot be built at the
> same time from one config; flip the brand and rebuild. See
> [`../docs/03-edgeai-image.md`](../docs/03-edgeai-image.md).

## Other pinned decisions (and why)
- `IMAGE_BOOT_FILES` copies `sysfw-j721e-gp-evm.itb` **as** `sysfw.itb` — the J721E
  uses **split boot**; a missing `sysfw.itb` makes the board appear dead. See
  [`../docs/02-minimal-image.md`](../docs/02-minimal-image.md).
- `INHERIT += "rm_work"` + `RM_OLD_IMAGE = "1"` — mandatory on a disk-tight host.
- `PRSERV_HOST = ""` — the PR service is off; it raises fatal errors on the
  intentional 11.02→11.00 SDK downgrade (see [`../docs/05-tidl-version-matching.md`](../docs/05-tidl-version-matching.md)).
- `python3-paho-mqtt` is added **only** to `tisdk-edgeai-image` (the ADAS app
  needs MQTT; the minimal image stays lean).
