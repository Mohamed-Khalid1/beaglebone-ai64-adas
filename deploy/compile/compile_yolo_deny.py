#!/usr/bin/env python3
"""Compile YOLO with an env-driven deny_list (ops kept on A72). Output still = output0;
denied ops just run on CPU EP at runtime. Used to dodge the 11_00_06 perfsim hang."""
import os, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import config as C
import preprocess as P
from tidl_common import compile_model

deny = os.environ.get("BBAI64_YOLO_DENY", "").strip() or None
print(f"[deny-compile] deny_list = {deny!r}")
compile_model(C.YOLO.ONNX, C.YOLO.TIDL_DIR, P.preprocess_yolo, deny_list=deny)
