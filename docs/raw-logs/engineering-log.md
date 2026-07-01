# BeagleBone AI-64 ADAS Deployment — Engineering Log (2026-06-27)

Comprehensive technical record of deploying a custom ADAS perception stack (object detection +
lane/drivable-area segmentation) onto the **C7x DSP accelerator** of a BeagleBone AI-64, including
every TIDL compiler workaround, hardware limitation, and the final deployable state. For thesis /
graduation-project documentation.

---

## 1. Platform & toolchain

| Item | Value |
|---|---|
| Board | BeagleBone AI-64 — TI **TDA4VM / J721E**, dual Cortex-A72 (A72) + **C7x-MMA DSP** |
| Image | Custom 11.00 EdgeAI Yocto (arago), kernel **6.6.58-ti** |
| On-device runtime | **onnxruntime 1.15.0** with `TIDLExecutionProvider` |
| **TIDL firmware net-version** | **`0x20250429`** (FIXED in the flashed image — central constraint) |
| C7x device | `64800000.dsp` (remoteproc index **not stable** across boots — find by name) |
| Host compile env | x86-64 Ubuntu; `~/edgeai-tidl-tools/gpvenv` (Python 3.10, **onnxruntime-tidl 1.15.0**, onnx 1.14, cv2 4.11) |
| TIDL tools used | `~/edgeai-tidl-tools/tools/J721E_1100_06/tidl_tools` (SOC=am68pa, commit a20dedb0) — **the only release that stamps the board-accepted `0x20250429`** |
| Host↔board link | USB-C **gadget** (`g_ether`), host `192.168.7.1` / board `192.168.7.2`, NM profile `bbai64-usb`. Throughput ~**25.5 MB/s**. (Wired eth0 stayed link-down all session.) |

**Two-phase TIDL flow:** *compile* (x86 only, via `TIDLCompilationProvider` — quantizes to INT8/INT16,
picks C7x-vs-A72 per-layer offload, writes artifacts) → *inference* (board, `TIDLExecutionProvider`,
loads artifacts). A key debugging tool: **the compiled artifacts can be run on the x86 host with
`TIDLExecutionProvider` (PC-emulation)** — it reproduces the board's quantized output without the
board, enabling fast accuracy debugging.

---

## 2. The governing hardware/firmware constraints (discovered)

These shaped every decision:

1. **Net-version is a fixed acceptance WINDOW.** The board accepts only nets stamped `0x20250429`.
   - 10_01 tools (`0x20241120`) → **rejected** (too old): `cmd_status -1`, `TIVX_CMD_NODE_CREATE failed`.
   - 11_00_07 / 11_00_08 j721e tools (`0x20250630`) → **rejected** (too new): same error.
   - Patching the stamp in the `.bin` passes the gate but the net then **hangs the C7x** (format
     mismatch) → version-patching is a dead end.
   - ⇒ Must compile with the **11_00_06** release (stamps `0x20250429`).
2. **Heavy TIDL subgraphs RESET the board.** Loading an oversized net onto the C7x triggers a full
   board reset (watchdog). Observed thresholds: YOLO INT16 (7.3 MB) reset; UFLD FC (196 MB) reset
   instantly; YOLO INT8 (5 MB) and TwinLite (2–3 MB) were stable.
3. **The board's TIDL cannot verify complex "head" ops** (`Reshape`, `Slice`). The inference-time EP
   re-partitions the ONNX graph itself, and `deny_list` / `max_num_subgraphs` are **compile-only —
   ignored at inference**. So any unsupported head must be physically removed from the ONNX (graph
   truncation), not denied.
4. **Repeated SIGKILL of board TIDL sessions leaks `tiovx` object descriptors** in shared memory
   managed by the **MCU R5F (`mcu2_0`, which does NOT reset on a Linux reboot)** → eventual
   `Exceeded max object descriptors` / `vxCreateContext failed`. Requires a **full power cycle** to
   clear (Linux reboot is insufficient).

---

## 3. YOLO object detector — ✅ DEPLOYED & WORKING

**Model:** teammate's fine-tuned **yolo26n**, 8 classes (CARLA domain:
`vehicle, bike, motobike, traffic_light, pedestrian, sign_30, sign_60, sign_90`).

### Pipeline
1. **Export** (`best.pt` → ONNX): force `head.end2end=False` (the `.pt` is NMS-free end2end, output
   `[1,300,6]`; we need the raw one2many head `[1,12,8400]`), `dynamic=False`, `nms=False`, opset 11.
2. **SPPF surgery:** TIDL has no 5×5 stride-1 maxpool. Replaced each of the 3 SPPF `MaxPool 5×5`
   (pad 2) with **two chained `MaxPool 3×3` (pad 1)** — exact max-pool identity — then
   `onnx.shape_inference`. (Note: this yolo26n is reg_max=1, i.e. **no DFL** — `cv2` heads output 4
   raw box channels directly.)
3. **Head truncation (the key fix):** the board's TIDL fails graph-verify on the detection head
   (`/model.23/Reshape_3`). Cut the ONNX at the **6 raw detection-conv outputs**
   (`cv2.{0,1,2}.2/Conv` box `[1,4,H,W]` + `cv3.{0,1,2}.2/Conv` cls `[1,8,H,W]`, H,W = 80/40/20)
   via `onnx.utils.extract_model`. Backbone + conv-heads → C7x; decode → A72.
4. **Compile:** 11_00_06 tools, **INT8** (`tensor_bits=8`).
   - *Compiler hang note:* the full-head model **hangs the INT8 perfsim**; INT16 fixed the full model
     but reset the board — **head truncation removes the hang entirely** and INT8 stays light.
   - Result: **1 subgraph, net `0x20250429`, io.bin 94616 (J721E 1-core), net.bin 5.0 MB, 352/352
     nodes offloaded.**
5. **Numpy decode on A72** (`yolo_runtime.py`): per scale (stride 8/16/32), `sigmoid(cls)`, anchor
   points `(grid+0.5)*stride`, `dist2bbox` ltrb→xyxy `(ax−l, ay−t, ax+r, ay+b)*stride`, gather 3
   scales → class-aware NMS. **Validated exact** vs the full ONNX head (box max-diff 9e-5, cls 1e-7;
   detections match the full model on 6/6 calib images).

### Measured results (on board)
- **Verify + run: PASS**, `1 subgraph, 352 nodes offloaded`.
- **Inference 16.0 / 16.1 / 16.2 ms** (min/avg/max over 100 iters) → **~62 FPS**.
- **Stress test: 100 consecutive C7x inferences, board did NOT reset, no link drop**, 0.2 ms jitter.
- **On-device end-to-end** (preprocess + C7x infer + numpy decode) on a real frame: correct
  detection (e.g. vehicle conf 0.753, box `[846,245,884,277]`, matching the PC float reference within
  ~5 px — the small delta is expected INT8 quantization).

**Deployable artifact:** `artifacts/yolo_tidl/` (INT8, `0x20250429`) + `artifacts/yolo26n_carla8_trunc.onnx`.

---

## 4. UFLDv2 lane detector — ❌ NOT VIABLE on this board

**Model:** Ultra-Fast-Lane-Detection-v2, CULane/ResNet-18, input `[1,3,320,1600]`, 4 outputs
(`loc_row, loc_col, exist_row, exist_col`).

- **Head-verify wall (solved):** board fails verify on its `slice_4` head (4× `Slice`+`Reshape` of
  the final FC `linear_1 [1,91224]`). Fixed by truncating at `linear_1` + numpy split (validated
  exact). Config/scripts: `UFLD.TRUNC_ONNX`, `compile_ufld_trunc.py`.
- **Fatal blocker — the classifier is a 747 MB fully-connected layer** (`m.cls.3`, `2048→91224`):
  - On C7x: the compiled FC subgraph is **196 MB INT8 → resets the board** on load.
  - On A72 CPU (full model): **2288 ms/frame** (≈0.4 FPS), memory-bandwidth-bound on the 747 MB
    weights. Profiling showed the **ResNet-18 backbone @ 320×1600 is 2134 ms** of that (≈18 GFLOPs),
    the FC only ~154 ms.
  - Backbone-on-C7x + FC-on-A72 split was attempted but the 780 MB float FC weights + a transpose
    copy exceeded the board's ~1.8 GB free RAM → memory reset.
- **Conclusion:** UFLDv2's grid-classifier head is architecturally too heavy for this 8-TOPS edge
  part — too big for the C7x, too slow for the A72. **Replaced with TwinLiteNet.**

---

## 5. TwinLiteNet lane + drivable-area — ⚙️ RUNS at 70 FPS (accuracy needs decoder retrain)

**Model:** TwinLiteNet (chequanghuy), ESPNet-C encoder + 2 ConvTranspose decoder heads, **0.4 M
params**, pretrained on BDD100K (`best.pth` 1.8 MB). Input `640×360`, two raw-logit seg heads
`da [1,2,360,640]` + `ll [1,2,360,640]`; decode = `argmax` over the 2-channel axis (numpy).

### What worked (engineering)
1. **Export** (CPU, legacy `dynamo=False`, needs `pip install onnxscript`; strip `module.` prefix).
2. **Remove Dual Attention (PAM/CAM)** before export (`model.encoder.sa = sc = nn.Identity()`):
   CAM's `ReduceMax/Sub/Expand` are TIDL-unsupported and **hang the compiler**. Near-lossless
   (PAM `gamma≈-4e-20`; CAM `gamma=0.58` but real-image impact tiny: drivable 26.2%→22.5%, lane
   identical). Resulting ops are conv-only: `Conv, ConvTranspose, BatchNorm, PRelu, Add, Concat, AveragePool`.
3. **`shape_inference(data_prop=True)`** — mandatory, else ConvTranspose output dims are "Unknown
   input dimension, not supported by TIDL".
4. **Compile** 11_00_06: **1 subgraph, net `0x20250429`, 127 nodes offloaded**, INT8 2.2 MB / INT16
   2.6 MB. No hang, no board reset (tiny model).
5. **On-board: PASS** — `da/ll [1,2,360,640]`, **14.1 ms / ~70 FPS**, board stable.

### The accuracy blocker (root-caused, definitively)
The board's quantized masks are wrong: **drivable ≈76% / lane ≈65% vs float 22% / 1%**, identical
across INT8, INT16, `accuracy_level=0/1`, and calibration-frame counts — so **not a calibration or
bit-width issue**. Using host TIDL PC-emulation: the **output logits explode to `[-34653, +28605]`
(INT16 rails ±32767) vs float `[-6.7, +3.1]`**, while every float intermediate tensor is well-behaved
(|max| < 11.6). ⇒ **TIDL `0x20250429` mis-quantizes the `ConvTranspose` decoder** (the only
decoder-unique op; encoder has none). This is a TIDL op-level defect, not a model problem.

### Every fix attempted (all blocked on this firmware)
| Approach | Outcome |
|---|---|
| Split encoder→C7x / decoder→CPU (`extract_model` at PReLU or Conv output) | **Encoder-only graph hangs the compiler** at any cut point |
| `deny_list:"ConvTranspose"` at compile | Compiles, but inference EP **re-offloads all 127 nodes** (deny ignored at run-time) |
| Replace `ConvTranspose(k2s2)` → `Conv1x1 + DepthToSpace` (mathematically EXACT; BN folded into the conv; float maxdiff 3e-6, both DCR/CRD) | **TIDL hangs the importer on `DepthToSpace`** (artifacts dir stays empty) |

ConvTranspose blows up; DepthToSpace won't compile — the two exact upsamplers are both unusable. The
**only remaining path is to retrain the decoder with `Resize(bilinear)+Conv`** (TIDL-friendly but not
weight-exact). Full recipe in **`twinlitenet-retrain-notes.md`**.

---

---

## 5b. Depth-Anything-V2 (metric depth) — ⚙️ RUNS on C7x but NON-VIABLE (too slow + INT8-broken)

**Model:** Depth-Anything-V2-Metric-Outdoor-Small (HF), DINOv2 **ViT** encoder + DPT head, input
`[1,3,518,518]`, output `predicted_depth [1,1,518,518]`. ONNX 1.8 MB + 95 MB external `.data`.
Op profile (555 nodes): MatMul 96, Reshape 77, Mul 73, Transpose 65, Conv 31, **LayerNorm 28**,
**Softmax 12**, Erf 12, Resize 5, ConvTranspose 2.

- **Compiled** (11_00_06, INT8): **16 TIDL subgraphs**, all net `0x20250429`, io 94616, 44 MB net.bin,
  clean (0 hangs/fallbacks). BUT only **23 of 555 nodes offload to the C7x** — the entire transformer
  (attention MatMul/Softmax/LayerNorm + the Reshape/Transpose plumbing) runs on the **A72**, with 16
  C7x↔A72 hand-offs.
- **On-board KPI:** session build 1.3 s; **inference 2530 ms/frame ≈ 0.40 FPS**; board did NOT reset;
  output shape correct `[1,1,518,518]`.
- **Accuracy:** INT8 output **collapses to a constant 39.31 m** everywhere, vs the float model's
  correct varying map `[3.13, 78.56] m` (mean 25.7, std 19.2) — an INT8 quantization failure of the
  offloaded layers (same class of issue as TwinLite's ConvTranspose).
- **Verdict:** doubly non-viable on this board — **CPU-bound at 0.4 FPS** (a ViT cannot be accelerated
  here: TIDL `0x20250429` keeps all attention on the A72) **and** the INT8 output is degenerate. INT16
  might recover accuracy but cannot fix the 2.5 s/frame latency. **Use `--no-depth`**; if metric depth
  is needed, it must be a lightweight CNN depth model, not a ViT.

**Artifacts:** `artifacts/depth_tidl/` (16 subgraphs), `artifacts/depth_anything_v2_metric_s.onnx(.data)`.

---

## 6. Reusable TIDL compiler workarounds discovered

- **Op-level limits @ `0x20250429`:** no 5×5 s1 MaxPool; `Reshape`/`Slice` heads fail board verify;
  `ConvTranspose` quantization overflows; `DepthToSpace` hangs the importer; CAM attention
  (`ReduceMax/Sub/Expand/MatMul/Softmax`) hangs the compiler.
- **`deny_list` / `max_num_subgraphs` are COMPILE-only** — the board's inference EP re-partitions
  independently. To control offload you must **physically truncate the ONNX**.
- **INT8 perfsim hang** on complex heads is fixed by **INT16** *or* by **removing the offending head**
  (truncation). Removing it is preferable (INT8 stays light → no board reset).
- **`shape_inference(data_prop=True)`** required after `extract_model`/surgery so TIDL sees concrete dims.
- **Empty `artifacts_folder` required** — a non-empty dir → "artifacts_folder is not empty" → silent
  CPU fallback → stale artifacts (verify via `onnxrtMetaData.txt` mtime). Zombie compile processes
  (setsid-detached) recreate the dir; kill by PID until 0.
- **Host TIDL PC-emulation** (`TIDLExecutionProvider` on x86 with the artifacts) reproduces board
  quantized output → debug accuracy without the board.
- **External-weight ONNX** (e.g. UFLD `.data`) must be present at inference — ORT loads all
  initializers before partitioning; you cannot ship a weight-stripped graph.

---

## 7. Final state of deployable artifacts

Repo root: `~/bbai-64-deploy/`. Artifacts: `bbai-64-deploy/artifacts/`. Board staging (persistent,
survives reboot): `/home/root/yg/`.

| Component | Files | State |
|---|---|---|
| **YOLO (deploy)** | `yolo_tidl/` (INT8, `0x20250429`, io 94616, 5 MB), `yolo26n_carla8_trunc.onnx` | ✅ **Deployable** — 16 ms / 62 FPS, on-board proven |
| YOLO runtime | `runtime/yolo_runtime.py` (numpy anchor decode), `config.YOLO.TRUNC_ONNX` | ✅ validated exact vs float |
| YOLO repro | `export/truncate_yolo_head.py` (md5-stable), `compile/compile_yolo_trunc.py` | ✅ |
| **TwinLite (runs, retrain pending)** | `twinlite_noattn.onnx` (attention-free), `twinlite_tidl/` | ⚙️ 70 FPS, masks need retrain |
| TwinLite intermediates | `twinlite.onnx`, `twinlite_d2s.onnx` (Conv+DepthToSpace, float-exact), `twin_enc*.onnx`, `twin_dec*.onnx` | reference for the retrain |
| TwinLite repo | `~/TwinLiteNet/` (model, `pretrained/best.pth`) | source for retrain |
| UFLD (not viable) | `ufld_culane_res18_trunc.onnx`, `ufld_tidl/`, `ufld_head_weights.npz` | archived; superseded |
| Retrain notes | `twinlitenet-retrain-notes.md` | decoder change + training recipe |

### Bottom line
- **Object detection (yolo26n): fully deployed on the C7x — 16 ms / 62 FPS, accurate, stress-tested.**
- **Lane + drivable-area: TwinLiteNet proven to run on the C7x at 70 FPS** (a real architectural win
  vs UFLDv2 which is physically un-deployable here); accuracy is **one decoder fine-tune away**
  (`ConvTranspose → Resize+Conv`), fully specified in the retrain note.
- **UFLDv2 conclusively shown non-viable** on this hardware (747 MB FC).

The 8-TOPS C7x with the fixed `0x20250429` firmware was pushed to its limits; the binding constraints
are the firmware op-support set, the net-version window, the heavy-net board-reset threshold, and the
~1.8 GB usable RAM — all documented above for reproducibility.
