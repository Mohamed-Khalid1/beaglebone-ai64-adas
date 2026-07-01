#!/usr/bin/env python3
"""Compile UFLD BACKBONE only (ResNet18+pool, output conv2d_20 [1,8,10,50]) -> C7x.
The view/LayerNorm/FC/slice head (only ~154ms, but its 196MB FC resets the C7x)
runs in numpy on the A72. 11_00_06 / INT8."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import config as C
import preprocess as P
from tidl_common import compile_model
ONNX = C.ARTIFACTS / "ufld_backbone.onnx"
compile_model(ONNX, C.ARTIFACTS / "ufld_bb_tidl", P.preprocess_ufld)
