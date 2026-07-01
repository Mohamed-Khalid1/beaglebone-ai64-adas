#!/usr/bin/env python3
"""
Stage 1a-bis (PC) — head-truncate the exported yolo26n ONNX for the BBAI-64.

WHY: the board's 0x20250429 TIDL firmware fails graph-verify on yolo26n's
detection head (the `/model.23/Reshape_3` subgraph) — and that decision is made by
the board's INFERENCE-time EP, so no compile-time deny_list/max_num_subgraphs can
avoid it. Fix: cut the graph at the 6 raw detection-conv outputs so only
backbone + conv-heads are offloaded to the C7x (all TIDL-verifiable), and run the
anchor decode + sigmoid + NMS in numpy on the A72 (runtime/yolo_runtime.py).

This yolo26n is reg_max=1 (cv2 outputs 4 channels = direct ltrb distances, no DFL),
so the 6 outputs are: per scale {cv2.s.2/Conv [1,4,H,W] box, cv3.s.2/Conv [1,nc,H,W] cls}.

    python export/truncate_yolo_head.py        # reads C.YOLO.ONNX, writes C.YOLO.TRUNC_ONNX
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import config as C  # noqa: E402


def main() -> None:
    try:
        import onnx
        from onnx import utils
    except Exception as e:  # noqa: BLE001
        sys.exit(f"[truncate] onnx not available ({e}); run on the PC venv.")

    if not C.YOLO.ONNX.exists():
        sys.exit(f"[truncate] missing {C.YOLO.ONNX} — run export/export_yolo_onnx.py first.")

    outs = [f"/model.23/cv{c}.{s}/cv{c}.{s}.2/Conv_output_0"
            for s in (0, 1, 2) for c in (2, 3)]
    utils.extract_model(str(C.YOLO.ONNX), str(C.YOLO.TRUNC_ONNX),
                        input_names=["images"], output_names=outs)

    m = onnx.load(str(C.YOLO.TRUNC_ONNX))
    onnx.checker.check_model(m)
    has_head = any(n.name == "/model.23/Reshape_3" for n in m.graph.node)
    print(f"[truncate] wrote {C.YOLO.TRUNC_ONNX}")
    for o in m.graph.output:
        print("  out", o.name, [d.dim_value for d in o.type.tensor_type.shape.dim])
    print(f"[truncate] head Reshape_3 removed: {not has_head}")
    print("[truncate] next: compile/compile_yolo_trunc.py (11_00_06 tools, BBAI64_TENSOR_BITS=8)")


if __name__ == "__main__":
    main()
