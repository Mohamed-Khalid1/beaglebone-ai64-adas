# 08 — Monocular depth (Depth-Anything-V2, ViT): non-viable ❌

The optional third model — **Depth-Anything-V2** (DINOv2 **ViT** encoder + DPT head,
518×518 input, 555 nodes: 96 MatMul, 28 LayerNorm, 12 Softmax, 77 Reshape, 65 Transpose)
— was tested for per-object distance estimation. It **compiles and runs on the board,
but is non-viable for two independent reasons.** Run the app with `--no-depth`.

## What we tried
Compiled the full ViT depth model with the `J721E_1100_06` tools (INT8) and ran it on
the board via [`deploy/runtime/depth_runtime.py`](../deploy/runtime/depth_runtime.py).
Compile is clean: 16 subgraphs, net-version `0x20250429`, no errors, no reset.

## Why it failed

### Blocker 1 — offload collapse (transformer ops unsupported)
It's a **Vision Transformer**, and TIDL at `0x20250429` doesn't accelerate the attention
ops (`MatMul` / `Softmax` / `LayerNorm`). Result: only **23 of 555 nodes offload to the
C7x** — all attention stays on the A72.
→ **2530 ms/frame (0.40 FPS)** — roughly 40× too slow for a real-time ADAS pipeline
that also has to run YOLO + lanes on the same single C7x.

### Blocker 2 — INT8 accuracy collapse
Under INT8 the depth map **degenerates to a near-constant 39.31 m**, versus the float
model's varying `[3.13, 78.56] m` range (std 19.2). The quantized output carries no
usable depth information.

## Conclusion
A transformer **cannot be accelerated on this firmware** — attention falls to the A72
(unusable latency) and INT8 quantization destroys the output. This is an architectural
mismatch between ViT models and this accelerator generation, not a tuning problem.

**Recommendation:** disable depth (`--no-depth`); metric depth on this hardware would
need a **lightweight CNN** depth model (convolutional, INT8-friendly), not a ViT.

## KPI
| Metric | Value |
|---|---|
| Latency | 2530 ms/frame |
| Throughput | 0.40 FPS |
| Nodes on C7x | 23 / 555 (attention on A72) |
| Accuracy | ❌ INT8 collapses to constant 39.31 m |
