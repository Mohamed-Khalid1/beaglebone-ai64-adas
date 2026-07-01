# TwinLiteNet → BBAI-64 C7x: decoder retrain notes

**Audience:** teammate doing the GPU fine-tune.
**Goal:** make TwinLiteNet's lane + drivable-area masks *accurate* when quantized and run on the
BeagleBone AI-64 C7x. The model already **runs at 70 FPS on the C7x** — the only problem is one
decoder op, fixed by a short fine-tune.

---

## 1. The problem (one sentence)
The board's fixed TIDL firmware (net-version `0x20250429`) **mis-quantizes `ConvTranspose`** (the
decoder upsampler): in INT8/INT16 the output logits explode to `~[-34653, +28605]` vs the float
`[-6.7, +3.1]`, which wrecks the argmax → masks become ~76% drivable / ~65% lane instead of the
correct ~22% / ~1%. The float model is perfect; it is purely a TIDL ConvTranspose quantization
defect. We exhausted every compile-time workaround (see §5); the only fix is to **replace
`ConvTranspose` with a TIDL-friendly upsampler and fine-tune**.

## 2. The exact code change
File: **`model/TwinLite.py`**, class **`UPx2`** (used by all 6 decoder stages: `up_1_1, up_2_1,
classifier_1, up_1_2, up_2_2, classifier_2`).

**Current (problematic):**
```python
class UPx2(nn.Module):
    def __init__(self, nIn, nOut):
        super().__init__()
        self.deconv = nn.ConvTranspose2d(nIn, nOut, 2, stride=2, padding=0, output_padding=0, bias=False)
        self.bn  = nn.BatchNorm2d(nOut, eps=1e-03)
        self.act = nn.PReLU(nOut)
    def forward(self, input):
        return self.act(self.bn(self.deconv(input)))
```

**Replace with (TIDL-friendly: Resize + Conv):**
```python
class UPx2(nn.Module):
    def __init__(self, nIn, nOut):
        super().__init__()
        # 2x bilinear upsample (TIDL 'Resize') + 3x3 conv — no ConvTranspose, no DepthToSpace.
        self.up   = nn.Upsample(scale_factor=2, mode='bilinear', align_corners=False)
        self.conv = nn.Conv2d(nIn, nOut, 3, stride=1, padding=1, bias=False)
        self.bn   = nn.BatchNorm2d(nOut, eps=1e-03)
        self.act  = nn.PReLU(nOut)
    def forward(self, input):
        return self.act(self.bn(self.conv(self.up(input))))
```
Notes:
- `Resize` (Upsample) + `Conv` are both well-supported and quantize cleanly on TIDL `0x20250429`
  (the encoder, which is all Conv/Pool, already runs perfectly).
- If bilinear is ever an issue at export, `mode='nearest'` also works (slightly lower quality).
- This changes the decoder weights, so it is **not** weight-exact → a fine-tune is required.

## 3. Training / fine-tune recipe
The encoder is unchanged, so you only need to (re)learn the 6 small decoder blocks — a short tune.

1. Apply the §2 change to `model/TwinLite.py`.
2. **Warm-start the encoder** from the released checkpoint, let the new decoders train from scratch:
   ```python
   net = TwinLiteNet()
   sd = torch.load('pretrained/best.pth', map_location='cpu')
   sd = { k.replace('module.',''): v for k,v in sd.items() }      # strip DataParallel prefix
   net.load_state_dict(sd, strict=False)   # encoder loads; new up_*/classifier_* conv start fresh
   ```
3. Train on **BDD100K** (same dataset the repo uses) with the repo's `train.py`:
   ```bash
   python train.py --max_epochs 50 --batch_size 16 --lr 5e-4
   # Adam(0.9,0.999) wd=5e-4, poly LR — all defaults already in train.py.
   ```
   50 epochs is usually enough since the encoder is pretrained; watch val drivable-mIoU (~91%)
   and lane-IoU (~31%) to confirm parity with the original.
4. (Optional, best INT8 accuracy) **QAT**: fine-tune a few epochs with TI's
   `edgeai-modeloptimization`/`edgeai-torchvision` quantization-aware wrappers so the model is
   robust to INT8. Not strictly required if INT16 is acceptable on-device.

## 4. Export → compile → verify (this part is already proven; reuse verbatim)
After training, produce the `best.pth`, then:

```python
# (a) EXPORT — CPU, legacy exporter, REMOVE the attention, run shape inference
import torch, torch.nn as nn, onnx
from onnx import shape_inference
from model.TwinLite import TwinLiteNet
m = TwinLiteNet().eval()
sd = torch.load('best.pth', map_location='cpu'); sd = {k.replace('module.',''):v for k,v in sd.items()}
m.load_state_dict(sd)
m.encoder.sa = nn.Identity(); m.encoder.sc = nn.Identity()   # drop PAM/CAM (see §5) — near-lossless
torch.onnx.export(m, torch.zeros(1,3,360,640), 'twinlite.onnx',
                  opset_version=12, input_names=['images'], output_names=['da','ll'], dynamo=False)
mm = shape_inference.infer_shapes(onnx.load('twinlite.onnx'), data_prop=True)   # REQUIRED for Resize/Conv dims
onnx.checker.check_model(mm); onnx.save(mm, 'twinlite.onnx')
```
- **Preprocess (must match training & runtime):** `cv2.resize(img,(640,360))`, BGR→RGB, CHW, `/255.0`.
- **Decode (numpy on A72):** `DA = da[0].argmax(0)`, `LL = ll[0].argmax(0)` → binary masks.

```bash
# (b) COMPILE on x86 with the board-matched tools (INT16 recommended for seg accuracy)
export TIDL_TOOLS_PATH=~/edgeai-tidl-tools/tools/J721E_1100_06/tidl_tools   # stamps net 0x20250429
export LD_LIBRARY_PATH=$TIDL_TOOLS_PATH:$LD_LIBRARY_PATH
# onnxruntime TIDLCompilationProvider, tensor_bits=16, accuracy_level=1,
# calibrate on ~16 real BDD road frames. (See compile/compile_twinlite*.py pattern.)
```

```python
# (c) VERIFY on the HOST without the board (TIDL PC-emulation reproduces the C7x quantized output):
ort.InferenceSession('twinlite.onnx',
    providers=['TIDLExecutionProvider','CPUExecutionProvider'],
    provider_options=[{'artifacts_folder':'twinlite_tidl'},{}])
# PASS criterion: da logits stay in a small range (~[-10,10], NOT tens-of-thousands),
# and argmax drivable/lane % match the float model within a few %.
```
Then copy `twinlite.onnx` + `twinlite_tidl/*.bin` to the board and run with `TIDLExecutionProvider`.

## 5. Hard-won gotchas (do not relearn these)
- **Remove the Dual Attention (PAM + CAM)** before export. CAM's `ReduceMax/Sub/Expand` are
  TIDL-unsupported and **hang the compiler**. It's near-lossless: PAM `gamma≈-4e-20` (zero), CAM
  `gamma=0.58`, but measured impact on real images is tiny (drivable 26.2%→22.5%, lane identical).
- **`shape_inference(data_prop=True)` is mandatory** — the exporter leaves upsampler output dims
  unknown → TIDL says "Unknown input dimension, not supported".
- **Do NOT use `ConvTranspose` or `DepthToSpace`** on this firmware: ConvTranspose quantization
  blows up; DepthToSpace hangs the importer. Resize+Conv is the safe upsampler.
- **INT16 over INT8** for segmentation (thin lanes are quantization-sensitive). TwinLite is tiny
  (~0.4M params) so INT16 (~3 MB) is fine and will NOT reset the board.
- TIDL compile needs an **empty `artifacts_folder`** (else it silently falls back to CPU and you
  get stale artifacts — check `onnxrtMetaData.txt` mtime).

**Done.** With the decoder swapped and fine-tuned, TwinLiteNet should give correct masks at ~70 FPS
on the C7x, matching the YOLO detector already deployed.
