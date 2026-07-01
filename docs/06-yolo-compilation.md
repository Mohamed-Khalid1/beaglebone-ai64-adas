# 06 — YOLO object detector: the deployable result ✅

The one model that ships: the teammate's fine-tuned **yolo26n** (8 CARLA classes,
`reg_max=1`, no DFL), running on the C7x at **16 ms / ~62 FPS**, accuracy matching the
float model (~5 px box error), 100-iteration stress stable with no board reset.

Getting there required three pieces of graph surgery plus cracking the version catch-22
from [doc 05](05-tidl-version-matching.md).

## Surgery 1 — `end2end=False` re-export (head truncation, part 1)
The `best.pt` was exported with the end-to-end detection head (`end2end=True`), which
bakes decode + NMS into the graph using ops the board can't verify. **Fix:** re-export
with `head.end2end=False` to get the raw head `[1, 12, 8400]`.
Code: [`deploy/export/export_yolo_onnx.py`](../deploy/export/export_yolo_onnx.py).

## Surgery 2 — SPPF 5×5 MaxPool → chained 3×3 (op substitution)
TIDL at `0x20250429` has **no 5×5 stride-1 MaxPool**. YOLO's SPPF block uses three of
them. Each 5×5 s1 MaxPool is **mathematically identical** to two chained 3×3 s1
MaxPools, so each was replaced by a 3×3 pair (exact identity, no accuracy loss),
followed by `shape_inference` to fix up dims.

## Surgery 3 — head truncation + NumPy decode (part 2)
Even with a raw head, the board **fails verify on the `Reshape` head**. **Fix:** cut the
ONNX graph at the **6 raw detection-conv outputs**, and do the decode
(anchor `dist2bbox` + sigmoid + class-aware NMS) **in NumPy on the A72**. The NumPy
decode was validated to match the float model exactly.
Code: [`deploy/export/truncate_yolo_head.py`](../deploy/export/truncate_yolo_head.py),
decode in [`deploy/runtime/yolo_runtime.py`](../deploy/runtime/yolo_runtime.py) +
[`deploy/runtime/pred2coords_np.py`](../deploy/runtime/pred2coords_np.py).

> This **head-truncation + NumPy-decode** pattern — move the unsupported head off the
> graph and run it on the A72 — is the general method that made YOLO deployable and is
> the template applied to the other models.

## Cracking the version catch-22
The custom yolo26n makes the **11.00 compile tools hang**, but the board **rejects**
what the older 10.01 tools produce (`0x20241120`, too old). The model therefore *had*
to be compiled on the exact `J721E_1100_06` tools that were hanging on it. The surgery
above is also what unblocked the compile: with the unsupported SPPF MaxPools replaced
and the problematic head removed, the graph the compiler has to quantize is small and
fully-supported, so `J721E_1100_06` compiles it cleanly instead of hanging.

Compile scripts: [`deploy/compile/compile_yolo_tidl.py`](../deploy/compile/compile_yolo_tidl.py),
[`compile_yolo_trunc.py`](../deploy/compile/compile_yolo_trunc.py),
[`compile_yolo_deny.py`](../deploy/compile/compile_yolo_deny.py).

## Final compile result
- Tools `J721E_1100_06`, **INT8** → 1 subgraph, net-version `0x20250429`, **5.0 MB**.
- **352 / 371 nodes offloaded to the C7x.**
- Artifact: `artifacts/yolo_tidl/` + `yolo26n_carla8_trunc.onnx` (fetched via
  [`deploy/fetch_artifacts.sh`](../deploy/fetch_artifacts.sh); not in git).

## KPI
| Metric | Value |
|---|---|
| Latency | **16 ms/frame** |
| Throughput | **~62 FPS** |
| Stability | 100-iter stress, no reset |
| Accuracy | matches float (~5 px box) |
| Precision | INT8 |
