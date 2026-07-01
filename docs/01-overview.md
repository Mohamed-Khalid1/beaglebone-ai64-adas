# 01 — Project overview

## Goal
Deploy a real-time **ADAS perception stack** — object detection + lane/drivable-area
segmentation (+ an attempt at monocular depth) — onto the **C7x-MMA DSP accelerator**
of a **BeagleBone AI-64** (TI TDA4VM / J721E), running custom-trained models for a
CARLA-simulated driving scenario.

The deployable target is the **TISDK EdgeAI image**. A stripped-down **minimal image**
was built first as the bring-up foundation — a fast, graphics-free platform to prove
boot, networking, and C7x enablement before layering the full EdgeAI/Qt stack on top.

## Platform
| Item | Value |
|---|---|
| SoC | TI TDA4VM / J721E — dual Cortex-A72 (ARM, "A72") + **C7x-MMA DSP** (~8 TOPS) |
| Board | BeagleBone AI-64, boot from microSD |
| OS | Custom Yocto image (TI Processor SDK, arago distro), kernel 6.6.58-ti |
| On-device inference | `onnxruntime 1.15.0` + TI's **`TIDLExecutionProvider`** (C7x backend) |
| Host compile env (x86) | TI **edgeai-tidl-tools**, `onnxruntime-tidl 1.15.0`, Py3.10 |

## The two images
| Image | Brand | Purpose | Doc |
|---|---|---|---|
| `bbai64-minimal-image` | `core` | Console + SSH + Python3 bring-up platform, no graphics | [02](02-minimal-image.md) |
| `tisdk-edgeai-image` | `edgeai` | Full C7x/MMA + Qt6/Weston ADAS target | [03](03-edgeai-image.md) |

Both are produced from the **same custom layer** (`yocto/meta-bbai64/`) by
flipping `ARAGO_BRAND` — see [`config/README.md`](../config/README.md).

## How the AI deployment works (two-phase TIDL flow)
1. **Compile on x86** (`TIDLCompilationProvider`): INT8/INT16 post-training
   quantization + per-layer decision of which nodes run on the C7x vs. fall back to
   the A72 + artifact generation.
2. **Infer on the board** (`TIDLExecutionProvider`): load the compiled artifacts and
   run on the C7x.
3. Compiled artifacts can also be run on the x86 host in **TIDL PC-emulation** mode,
   reproducing the board's quantized output for off-board debugging.

## Results at a glance
| Model | Task | Result | Latency | Status |
|---|---|---|---|---|
| YOLO (yolo26n, custom) | Object detection | **Deployed on C7x** | 16 ms / ~62 FPS | ✅ |
| TwinLiteNet | Lanes + drivable area | Runs on C7x, masks wrong | 14 ms / ~70 FPS | ⚙️ retrain-pending |
| UFLDv2 | Lane detection | Architecturally non-viable | — | ❌ |
| Depth-Anything-V2 (ViT) | Monocular depth | Non-viable (too slow + INT8-broken) | 2530 ms / 0.4 FPS | ❌ |

Full breakdown with root causes: [`results-kpis.md`](results-kpis.md).

## Reading order
1. This overview
2. [02 — minimal image](02-minimal-image.md) and [03 — EdgeAI image](03-edgeai-image.md)
3. [04 — C7x enablement](04-c7x-enablement.md)
4. [05 — TIDL version matching](05-tidl-version-matching.md) ← the binding constraint on everything
5. [06 — YOLO compilation](06-yolo-compilation.md) (the success) / [06b — UFLD](06b-ufld.md) (rejected)
6. [07 — lane detection / TwinLiteNet](07-lane-detection.md)
7. [08 — depth non-viable](08-depth-nonviable.md)
8. [09 — host resource constraints during the build](09-build-resource-constraints.md)
9. [results-kpis](results-kpis.md), then the primary-source logs in [`raw-logs/`](raw-logs/)
