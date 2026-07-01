# 07 — Lane + drivable-area detection (TwinLiteNet): runs, but not good enough ⚙️

**TwinLiteNet** (ESPNet-C encoder + two `ConvTranspose` decoder heads, **0.4 M
params**, trained on BDD100K) replaced the non-viable UFLDv2. It **runs on the C7x in
real time** — but its on-device output is **quantitatively wrong**, and we root-caused
exactly why. Honest verdict: **fast but not deployable as-is; needs a decoder retrain.**

## What worked
- **Fits the C7x:** compiles to 1 subgraph, net-version `0x20250429`, 2–3 MB,
  **127 / 127 nodes on the C7x**.
- **KPI: 14 ms/frame, ~70 FPS, no board reset.**
- Compile: [`deploy/compile/compile_twinlite_tidl.py`](../deploy/compile/compile_twinlite_tidl.py);
  runtime + NumPy argmax decode over the 2-channel heads:
  [`deploy/runtime/twinlite_runtime.py`](../deploy/runtime/twinlite_runtime.py).

### Surgery needed to compile it
- **Removed the Dual-Attention (PAM/CAM) blocks** — CAM's `ReduceMax / Sub / Expand`
  pattern **hangs the 11.00 compiler**. Removal is near-lossless (PAM γ ≈ 0; CAM γ = 0.58
  but negligible impact on real images).
- `shape_inference` to fix `ConvTranspose` output dims.

## Why it wasn't good — INT `ConvTranspose` overflow (root-caused)
On the board the quantized output **saturates**: drivable-area activation ~**76 %** and
lane ~**65 %**, versus the float reference's ~**22 %** and ~**1 %**. The masks are
effectively wrong despite the great FPS.

Root cause: **TIDL at `0x20250429` mis-quantizes `ConvTranspose`.** The decoder output
logits **explode to `[-34653, +28605]`** versus the float model's clean `[-6.7, +3.1]`.
The float ONNX is correct everywhere — this is a **structural TIDL operator
discrepancy**, not a threshold or calibration tweak.

### Every in-place fix is blocked by the fixed firmware
- Encoder/decoder split (compile encoder only) → **encoder-only compile hangs**.
- `deny_list` the `ConvTranspose` → **ignored at inference** (the EP re-partitions; see
  [doc 05](05-tidl-version-matching.md)).
- Replace `ConvTranspose` with the exact-equivalent `Conv + DepthToSpace` → **TIDL hangs
  the importer on `DepthToSpace`**.

## Conclusion & fix path
The only remaining fix is to **retrain the decoder with `Resize(bilinear) + Conv`**
instead of `ConvTranspose`, so the deployed graph avoids the broken operator entirely.
Recipe: [`raw-logs/twinlitenet-retrain-notes.md`](raw-logs/twinlitenet-retrain-notes.md).

This is still a real result: TwinLiteNet is an **architectural win over UFLDv2** (it
fits the C7x and runs at 70 FPS where UFLDv2 could not run at all) — it needs one
decoder fine-tune for correct masks, not a new model.

## KPI
| Metric | Value |
|---|---|
| Latency | 14 ms/frame |
| Throughput | ~70 FPS |
| Nodes on C7x | 127 / 127 |
| Accuracy | ❌ INT output saturates (ConvTranspose overflow) → retrain-pending |
