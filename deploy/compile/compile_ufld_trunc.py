#!/usr/bin/env python3
"""Compile HEAD-TRUNCATED UFLDv2 (cut at linear_1 [1,91224]) -> TIDL. 11_00_06, INT8,
deny LayerNorm to A72. The 4 head Slice+Reshape (loc_row/loc_col/exist_row/exist_col)
run in numpy on the A72 — the board's 0x20250429 TIDL can't verify the slice head."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import config as C
import preprocess as P
from tidl_common import compile_model
ONNX = C.ARTIFACTS / "ufld_culane_res18_trunc.onnx"
compile_model(ONNX, C.UFLD.TIDL_DIR, P.preprocess_ufld, deny_list="LayerNormalization")
