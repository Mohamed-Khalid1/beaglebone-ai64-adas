# bbai-64-deploy — compile status (2026-06-25)

On-host (x86) compilation of the teammate's ADAS stack for the BBAI-64 (TDA4VM,
board running the 11.00 edgeai Yocto image). Goal: flow test of `runtime/app.py` on
`drive-60s.mp4` with KPIs.

## STATUS: both models compiled to TIDL. Blocked on the on-board acceptance test.

### Artifacts (persisted here, in `bbai64-deploy/artifacts/`)
| model | tool ver | subgraphs | offload | net version | io.bin | notes |
|---|---|---|---|---|---|---|
| **YOLO** (yolo26n, 8-class) | **10_01_04_00** | 3 | **364/371 nodes** | `0x20241120` | 94616 ✓ | SPPF surgery + 10_01 tools |
| **UFLD** (CULane res18) | 11_00_12_00 | 2 | backbone + FC head | `0x20250429` | 94616 ✓ | LayerNorm head denied to A72 |

Both io.bin = **94616** = correct J721E 1-core size. Both net versions **< board window
`0x20250437`** (proven-accepted value `0x20250429`) → expected to pass the firmware
net-version check (reject-if-newer rule). **Mixed tool versions** (YOLO 10_01, UFLD 11_00) —
acceptable only if the 11.00 board runtime accepts older nets; **must verify on board**.

## The YOLO compile saga (root cause + fix — important)

YOLO would NOT compile with the **11.00 tools** (`11_00_12_00`): the TIDL **network
compiler hangs** (5 attempts, 18+ min each at 100% CPU, **0 "Successful Workload
Creation"**). Known TIDL issue (TI E2E forums: "process hangs after compilation", fixed by
changing tool versions). Two-part fix:

1. **SPPF op surgery (`artifacts/yolo26n_carla8.onnx`):** TIDL does not support 5×5 maxpool
   stride-1 (only 1×1/2×2/3×3). yolo26n's SPPF uses three 5×5 maxpools → forced 4 subgraphs.
   Replaced each **5×5 maxpool with two chained 3×3 maxpools** (max-pool identity: two 3×3
   pad-1 = one 5×5 pad-2), then `onnx.shape_inference`. Collapsed 4 subgraphs → 1.
   (The head DFL `Sub` (both-inputs-variable) is the only remaining CPU op.)
2. **Compiler version swap:** even as 1 subgraph the 11.00 compiler still hung. Switched to
   **`10_01_04_00` tools** (older, mature, no hang) → compiled in **~30 s**, 364/371 offloaded.

### YOLO export detail (also important)
`best.pt` is an **end2end (NMS-free) yolo26n** (`head.end2end=True`, output `[1,300,6]`).
The repo's `yolo_runtime.decode` expects the **raw head `[1,12,8400]`** + numpy NMS. So we
re-export with `head.end2end=False` to get the raw one2many head. (Done in the export step;
if re-exporting, set `end2end=False` before `model.export(..., nms=False)`.)

## Build environment (host)
- `~/edgeai-tidl-tools/gpvenv` — Python 3.10, **onnxruntime-tidl 1.15.0** (matches board ORT 1.15.0), cv2 4.11, numpy 1.23.
- tidl_tools downloaded per-version (28 MB each):
  - `~/edgeai-tidl-tools/tools/J721E_1100/tidl_tools` (= `11_00_12_00`, hangs on YOLO)
  - `~/edgeai-tidl-tools/tools/J721E_1001/tidl_tools` (= `10_01_04_00`, **use this for YOLO**)
- ultralytics 8.4.78 (system py, for YOLO export); torch 2.9.1; UFLD needs `addict` + `onnxscript`.
- UFLD checkpoint: `Ultra-Fast-Lane-Detection-v2/culane_res18.pth` (Drive id `1oEjJraFr-3lxhX_OXduAGFWalWa6Xh3W`).
- Test video: `~/minimal_image/link_smoke_test/videos/drive-60s.mp4` (CARLA city, 1280×720, 25fps, 60s).

### Compile commands (reproduce)
```bash
cd /home/mohamedkhalid/bbai-64-deploy
export LD_LIBRARY_PATH=$TIDL_TOOLS_PATH:$LD_LIBRARY_PATH
export BBAI64_ACCURACY_LEVEL=0 BBAI64_CALIB_FRAMES=4 BBAI64_CALIB_ITERS=1   # fast/flow-grade calib
PY=~/edgeai-tidl-tools/gpvenv/bin/python
# YOLO (10_01 tools, SPPF-fixed onnx already in artifacts/):
TIDL_TOOLS_PATH=~/edgeai-tidl-tools/tools/J721E_1001/tidl_tools $PY bbai64-deploy/compile/compile_yolo_tidl.py
# UFLD (11_00 tools, deny LayerNorm):
TIDL_TOOLS_PATH=~/edgeai-tidl-tools/tools/J721E_1100/tidl_tools $PY bbai64-deploy/compile/compile_ufld_tidl.py
```
Edits made to the repo (in this copy): `compile/tidl_common.py` (env-driven
accuracy_level / calib frames+iters / `BBAI64_MAX_SUBGRAPHS`, `debug_level=0`);
`compile/compile_ufld_tidl.py` (`deny_list="LayerNormalization"`).

## NEXT (when board is reconnected)
1. **Decisive test (cheap, ~15 MB):** copy `artifacts/yolo26n_carla8.onnx` + `artifacts/yolo_tidl/`
   to the board, run a standalone onnxruntime+TIDLExecutionProvider inference. **Does the
   11.00 runtime accept the 10_01 net (`0x20241120`)?** Pass = offload works, no `cmd_status -1`.
   - If REJECTED: recompile YOLO once an 11.00-compatible compile path is found, OR test whether
     the firmware truly is reject-newer.
2. If accepted: optionally recompile UFLD with 10_01 too (consistent stack), then deploy the
   full set. **UFLD ONNX carries an 825 MB `.data` file** → copy over board **eth0** (wired),
   not the USB gadget (~80 min otherwise).
3. `python3 runtime/preflight.py` then
   `python3 runtime/app.py --source video --video drive-60s.mp4 --no-depth` → annotated mp4 +
   JSON + `runtime/runtime_kpis.csv` / `runtime_analytics.txt`.

## Board facts
- 11.00 edgeai image, kernel 6.6.58-ti, ORT 1.15.0 + TIDLExecutionProvider, deps present
  (numpy/cv2/yaml/paho-mqtt). C7x runs (proven earlier: regnetx 103/103 offloaded).
- USB gadget MAC unpinned on first cold plug (host iface = `usb0`, random MAC); pins to
  `enxaabbcc000001` / board `fe80::a8bb:ccff:fe00:2` after first reset. Auto-detect the iface.
