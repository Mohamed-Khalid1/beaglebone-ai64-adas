#!/usr/bin/env python3
"""Compile the HEAD-TRUNCATED yolo26n (6 raw conv outputs) -> TIDL. INT16, 11_00_06.
Decode (anchor + sigmoid + NMS) runs in numpy on A72."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import config as C
import preprocess as P
from tidl_common import compile_model
ONNX = C.ARTIFACTS / "yolo26n_carla8_trunc.onnx"
compile_model(ONNX, C.YOLO.TIDL_DIR, P.preprocess_yolo)
