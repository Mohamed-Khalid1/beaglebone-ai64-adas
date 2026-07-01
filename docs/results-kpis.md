# Results & KPIs — summary

One model shipped; three rejected with clear root causes. The negative results are as
much a contribution as the positive one: they map the real operating envelope of the
C7x-MMA at TIDL net-version `0x20250429`.

## Per-model summary
| Model | Task | Latency | FPS | Nodes on C7x | Verdict | Why |
|---|---|---:|---:|---|---|---|
| **YOLO** (yolo26n, custom) | Object detection | **16 ms** | **62** | 352/371 | ✅ **Deployed** | SPPF + head surgery made it fit; accuracy = float | 
| **TwinLiteNet** | Lanes + drivable area | 14 ms | 70 | 127/127 | ⚙️ Runs, masks wrong | INT `ConvTranspose` overflow → retrain decoder |
| **UFLDv2** | Lane detection | 2288 ms (A72) | 0.4 | resets C7x | ❌ Non-viable | 747 MB FC head — too heavy for 8 TOPS |
| **Depth-Anything-V2** (ViT) | Monocular depth | 2530 ms | 0.4 | 23/555 | ❌ Non-viable | ViT attention unsupported + INT8 collapses |

## Key technical findings (contributions)
1. **Net-version is a fixed acceptance window.** The board accepts only `0x20250429`;
   both too-old (10_01 → `0x20241120`) and too-new (11_00_08 → `0x20250630`) nets are
   rejected. Must compile with the exact `J721E_1100_06` release. Patching the stamp
   passes the gate but then hangs the C7x. → [doc 05](05-tidl-version-matching.md)
2. **`deny_list` / `max_num_subgraphs` are compile-time-only** — the inference EP
   re-partitions the graph and ignores them. To control offload you must **physically
   truncate the ONNX graph**.
3. **Head-truncation + NumPy-decode** (move the unsupported head off the graph, run it
   on the A72) is the general method that made YOLO deployable and is the template for
   the rest. → [doc 06](06-yolo-compilation.md)
4. **Heavy subgraphs reset the board** (watchdog): INT16 YOLO 7.3 MB and UFLD FC 196 MB
   reset; ≤ 5 MB stable.
5. **Unsupported-op map @ `0x20250429`:** no 5×5 s1 MaxPool; `Reshape`/`Slice` heads
   fail board-verify; `ConvTranspose` INT quantization overflows; `DepthToSpace` hangs
   the importer; attention ops hang the compiler or fall to the A72.
6. **TIDL PC-emulation on x86** reproduces the board's quantized output — the efficient
   way to debug quantization accuracy without the board in the loop.

## Limitations (hardware/firmware)
- Fixed `0x20250429` firmware (no reflash in scope) → narrow op support + version gate.
- ~8 TOPS C7x + ~1.8 GB usable RAM → heavy FC / ViT models don't fit or don't accelerate.
- No transformer acceleration; weak/incorrect `ConvTranspose` and `DepthToSpace`.
- Watchdog board-reset on oversized nets.

## Conclusions & future work
- **Object detection runs in real time on the C7x (62 FPS)** — the deployable result.
- **Lanes (TwinLiteNet) proven at 70 FPS** — a real architectural win over UFLDv2; needs
  one decoder fine-tune (`ConvTranspose → Resize + Conv`) for correct masks.
- **Depth (ViT) is non-viable** on this firmware; recommend a lightweight CNN.
- **Future:** (a) TwinLite decoder retrain; (b) CNN depth; (c) rebuild the image on a
  newer TIDL (e.g. 11_02) to widen op support / lift the version gate; (d) the full
  3-model `app.py` pipeline once lanes are accurate.
