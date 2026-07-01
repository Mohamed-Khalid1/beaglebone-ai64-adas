#!/usr/bin/env python3
"""Compile the attention-free TwinLiteNet (twinlite_noattn.onnx) -> TIDL.

11_00_06 tools (stamps net-version 0x20250429, the board-accepted window). INT16 by
default (override BBAI64_TENSOR_BITS=8). Conv-only graph → 127/127 nodes offload to
C7x; tiny artifact (~2-3 MB) so no board reset. Decode (argmax over the 2-ch da/ll
heads) runs in numpy on the A72 (runtime/twinlite_runtime.py).
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import config as C
import preprocess as P
from tidl_common import compile_model

os.environ.setdefault("BBAI64_TENSOR_BITS", "16")   # INT16 default for the decoder

compile_model(
    C.TWINLITE.ONNX,
    C.TWINLITE.TIDL_DIR,
    P.preprocess_twinlite,
    tensor_bits=int(os.environ["BBAI64_TENSOR_BITS"]),
)
