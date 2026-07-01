# 06b — UFLDv2 lane detector: architecturally non-viable ❌

**Ultra-Fast-Lane-Detection-v2** (CULane / ResNet-18 backbone, 320×1600 input) was the
first lane-detection candidate. It was rejected on **model-architecture grounds** and
replaced by TwinLiteNet ([doc 07](07-lane-detection.md)).

## What we tried
- Exported UFLDv2 to ONNX (with an `ir_version 10 → 9` downgrade so the TIDL tools would
  accept the graph — [`deploy/export/export_ufld_onnx.py`](../deploy/export/export_ufld_onnx.py)).
- Applied the same **head-truncation** trick that worked for YOLO: truncate at the FC
  `linear_1` layer and do the grid→coordinate split in NumPy. This *did* clear the
  board head-verify wall.
- Compile attempts: [`deploy/compile/compile_ufld_tidl.py`](../deploy/compile/compile_ufld_tidl.py),
  [`compile_ufld_trunc.py`](../deploy/compile/compile_ufld_trunc.py),
  [`compile_ufld_backbone.py`](../deploy/compile/compile_ufld_backbone.py).

## Why it failed — the classifier head is a **747 MB fully-connected layer**
UFLDv2 frames lane detection as **row-wise grid classification**: its head is a single
enormous FC layer (`2048 → 91224`). That does not fit an ~8-TOPS edge accelerator:

- On the **C7x**, the ~196 MB INT8 FC subgraph **resets the board** (watchdog — over the
  ~5 MB stable threshold documented in [doc 05](05-tidl-version-matching.md)).
- On the **A72** (CPU fallback of the full model), inference is **2288 ms/frame
  (0.4 FPS)** — the ResNet-18 backbone at 1600 px alone is 2134 ms of that.
- The exported weight blob was ~**825 MB** — so large it had to be transferred to the
  board over wired `eth0`, not the USB-C gadget.

There is no graph surgery that fixes this: the FC head **is** the model's design. Either
it runs on the C7x and resets the board, or it runs on the A72 and is 100× too slow.

## Conclusion
The grid-classifier head is fundamentally too heavy for this class of accelerator.
**Rejected → replaced by TwinLiteNet** (0.4 M params, a fully-convolutional
encoder/decoder that fits the C7x). This is a genuine architectural finding: the
lane-detection *approach*, not just the tuning, determines edge viability.
