# BeagleBone AI-64 — Edge-AI ADAS on the C7x DSP

End-to-end graduation project: building custom Yocto Linux images for the **BeagleBone
AI-64** (TI TDA4VM / J721E) and deploying an **ADAS perception stack** — object
detection + lane/drivable-area segmentation (+ a depth attempt) — on its on-chip
**C7x-MMA DSP accelerator** through TI's **TIDL** runtime, with a full record of every
problem hit and how it was solved.

The deployable target is the **TISDK EdgeAI image**; a stripped-down **minimal image**
was built first as the bring-up foundation.

---

## Results

| Model | Task | Latency | FPS | Status |
|---|---|---:|---:|---|
| **YOLO** (yolo26n, custom) | Object detection | **16 ms** | **62** | ✅ deployed on C7x |
| **TwinLiteNet** | Lanes + drivable area | 14 ms | 70 | ⚙️ runs; masks need decoder retrain |
| **UFLDv2** | Lane detection | — | — | ❌ non-viable (747 MB FC head) |
| **Depth-Anything-V2** (ViT) | Monocular depth | 2530 ms | 0.4 | ❌ non-viable (ViT + INT8 collapse) |

Full analysis incl. root causes for the three rejections: [`docs/results-kpis.md`](docs/results-kpis.md).

---

## Reproduce / Run

There are two paths. **Start with A** — it runs inference in minutes with no build.

### A. Run inference (no Yocto build needed)
Prereqs: an x86-64 Linux host with the TI **edgeai-tidl-tools** `J721E_1100_06` release
installed and its Python venv active (onnxruntime-tidl 1.15.0, numpy, opencv, pyyaml).

```bash
git clone https://github.com/Mohamed-khalid1/beaglebone-ai64-adas.git
cd beaglebone-ai64-adas/deploy

./fetch_artifacts.sh                       # pulls compiled artifacts + weights (GitHub Release)
python3 runtime/yolo_runtime.py --image samples/sample.jpg   # single-frame demo
# or the full pipeline:
./run_native.sh                            # see deploy/README.md for flags (--no-depth, MQTT, …)
```
> The compiled C7x artifacts and model weights are multi-GB and therefore **not in git**
> — `fetch_artifacts.sh` downloads them from this repo's GitHub Release. A sample input
> (`deploy/samples/sample.jpg`) is committed so the demo runs with zero external data.

### B. Rebuild the Yocto image (full reproduction)
> The TI Processor SDK build tree is 100+ GB and **cannot be uploaded**; this repo ships
> the **custom layer** and the **exact `local.conf`** so the image is reproducible, not
> guessed. Point them at an installed TI SDK (Scarthgap 5.0 / arago).

```bash
# 1. Drop the custom layer into your SDK and add it to bblayers.conf
cp -r yocto/meta-bbai64-minimal  <TISDK>/sources/

# 2. Use the pinned build config (edit the 3 host paths at the top)
cp config/local.conf.example  <TISDK>/build/conf/local.conf

# 3. Build. ARAGO_BRAND in local.conf selects the image:
cd <TISDK> && source sources/oe-core/oe-init-build-env build
#   ARAGO_BRAND = "edgeai"  ->  bitbake tisdk-edgeai-image      (the ADAS target)
#   ARAGO_BRAND = "core"    ->  bitbake bbai64-minimal-image    (bring-up image)

# 4. Flash the resulting .wic.xz (identify the device with lsblk FIRST!)
scripts/flash.sh /dev/sdX
```
The `local.conf` is this project's equivalent of a "constraint file" — it pins every
non-default build decision. See [`config/README.md`](config/README.md).

### Connect to the board
```bash
scripts/board-login.sh            # USB-C gadget → configures host + ssh root@192.168.7.2
```
Login is `root` with an **empty password** (`debug-tweaks`). Details + IPv6 rescue path:
[`docs/raw-logs/BOARD_LOGIN_GUIDE.md`](docs/raw-logs/BOARD_LOGIN_GUIDE.md).

---

## Repository layout
| Path | Contents |
|---|---|
| [`docs/`](docs/) | Engineering narrative — start at [`01-overview.md`](docs/01-overview.md) |
| [`docs/raw-logs/`](docs/raw-logs/) | Primary-source session logs (appendix) |
| [`yocto/meta-bbai64-minimal/`](yocto/meta-bbai64-minimal/) | The custom Yocto layer (both images, USB gadget, C7x DT, uEnv) |
| [`config/`](config/) | The exact `local.conf` + the `ARAGO_BRAND` brand-toggle explainer |
| [`scripts/`](scripts/) | Flash the SD card, connect to the board over USB-C |
| [`deploy/`](deploy/) | Model export → compile (x86) → C7x runtime + `fetch_artifacts.sh` |
| [`models/twinlitenet/`](models/twinlitenet/) | Lane-detection model code |

## Documentation map
1. [Overview](docs/01-overview.md)
2. [Minimal image](docs/02-minimal-image.md) · [EdgeAI image](docs/03-edgeai-image.md)
3. [C7x enablement](docs/04-c7x-enablement.md)
4. [**TIDL version matching**](docs/05-tidl-version-matching.md) — the constraint behind everything
5. [YOLO (deployed)](docs/06-yolo-compilation.md) · [UFLD (rejected)](docs/06b-ufld.md)
6. [TwinLiteNet lanes](docs/07-lane-detection.md) · [Depth ViT (rejected)](docs/08-depth-nonviable.md)
7. [Host resource constraints during the build](docs/09-build-resource-constraints.md)
8. [Results & KPIs](docs/results-kpis.md)

## Platform
TI TDA4VM / J721E — dual Cortex-A72 + C7x-MMA DSP (~8 TOPS). Custom Yocto image (TI
Processor SDK, arago), kernel 6.6.58-ti. On-device inference: onnxruntime 1.15.0 +
`TIDLExecutionProvider`. Compiled on x86 with edgeai-tidl-tools `J721E_1100_06`.

## Acknowledgements
Custom-trained YOLO / lane models and the CARLA integration are joint graduation-project
work with the team ([LAITH-2026/bbai-64-deploy](https://github.com/LAITH-2026/bbai-64-deploy)).
This repository documents the **embedded bring-up + on-device C7x/TIDL deployment**.
