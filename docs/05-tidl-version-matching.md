# 05 — TIDL version matching (the binding constraint on everything)

This is the single most important — and most painful — finding of the project. Every
model result in docs 06–08 is downstream of it.

## The core fact: net-version is a fixed acceptance **window**

The flashed board firmware exposes a TIDL **net-version**, and in our image that value
is **fixed** at `0x20250429` (we could not recompile/reflash the firmware within the
project's scope). A compiled model artifact carries the net-version stamped by the
**compile tool release** that produced it. The board accepts an artifact **only if its
net-version falls inside the firmware's acceptance window** — and that window is
narrow:

| Compiled with | Stamps net-version | Board (`0x20250429`) verdict |
|---|---|---|
| `10_01_04_00` tools | `0x20241120` (too **old**) | ❌ rejected — `cmd_status -1`, `TIVX_CMD_NODE_CREATE failed` |
| **`J721E_1100_06`** tools | **`0x20250429`** | ✅ **accepted** |
| `11_00_08` tools | `0x20250630` (too **new**) | ❌ rejected |

So the board accepts **neither too-old nor too-new** nets. Only the exact
`J721E_1100_06` release stamps the accepted `0x20250429`.

> **Patching the version stamp doesn't work.** Editing the artifact's stamp to
> `0x20250429` passes the acceptance gate — and then **hangs the C7x** at inference,
> because the artifact's actual layer encoding doesn't match the firmware. The version
> field is a real compatibility marker, not a checkbox.

## The version-matching chain (three separate layers, all had to agree)

1. **Board firmware net-version** — fixed `0x20250429` (in the flashed image).
2. **On-device runtime** — the `onnxruntime` TIDL EP shipped in the image.
   Early mismatch: an **11.02 model** (io.bin 378392 B) against an **11.01
   runtime/firmware** (94616 B) failed. Fixed by pinning the SDK model version in
   [`edgeai-tidl-models.bbappend`](../yocto/meta-bbai64/recipes-tisdk/edgeai-components/edgeai-tidl-models.bbappend)
   → `EDGEAI_SDK_VERSION = 11_01_00`, and building the whole image on the 11.00 SDK.
3. **x86 compile tools** — must be the `J721E_1100_06` edgeai-tidl-tools release, the
   only one that stamps `0x20250429`.

Get any of the three out of sync and the model is rejected or hangs.

## Two consequences that shaped the whole deployment

### A. `deny_list` / `max_num_subgraphs` are **compile-time-only**
You cannot steer which nodes run on the C7x from the inference side — the inference EP
**re-partitions the graph itself and ignores those options**. The only reliable way to
keep an unsupported operator off the accelerator is to **physically truncate the ONNX
graph** and do that part on the A72. This is why every model here uses the
*head-truncation + NumPy-decode* pattern (see [06](06-yolo-compilation.md)).

### B. Oversized subgraphs reset the board (watchdog)
Observed thresholds on this firmware: INT16 YOLO at 7.3 MB and the UFLD FC subgraph at
196 MB both **reset the board**; artifacts ≤ 5 MB run stable. This is why the pipeline
targets small, INT8, head-truncated graphs.

## Unsupported-op map at `0x20250429` (learned the hard way)
- No **5×5 stride-1 MaxPool** (breaks YOLO's SPPF → op surgery, doc 06).
- **`Reshape` / `Slice` detection heads** fail board-verify (→ head truncation, doc 06).
- **`ConvTranspose`** INT quantization **overflows** (→ TwinLiteNet masks wrong, doc 07).
- **`DepthToSpace`** hangs the importer.
- **Attention ops** (`MatMul` / `Softmax` / `LayerNorm` / `ReduceMax`) hang the compiler
  or fall back to the A72 (→ ViT depth non-viable, doc 08).

## The catch-22 this created for YOLO
The custom YOLO (yolo26n) makes the 11.00 compile tools **hang**, while the older 10.01
tools compile it fine — but the board **rejects** 10.01's `0x20241120` net-version. So
the model *must* be compiled on the exact `J721E_1100_06` tools that hang on it. How
that was cracked is [06 — YOLO compilation](06-yolo-compilation.md).

Primary sources: [`raw-logs/COMPILE_STATUS.md`](raw-logs/COMPILE_STATUS.md),
[`raw-logs/engineering-log.md`](raw-logs/engineering-log.md).
