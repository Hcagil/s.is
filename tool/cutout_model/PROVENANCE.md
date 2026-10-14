# Bundled cut-out model: provenance

`assets/models/u2netp.onnx` is the on-phone fallback for sticker cut-out
(used when ML Kit / Apple Vision is unavailable). It is bundled, never
downloaded at runtime.

| Item | Value |
|---|---|
| Model | U2-NetP (https://github.com/xuebinqin/U-2-Net), Apache-2.0 |
| Source of weights | official `u2netp.pth`, Google Drive id `1rbSTGKAE-MTxBYHd-51l2hMOQPT_7EPy` (linked from the repo README) |
| Model code | `model/u2net.py` at commit `ac7e1c817ecab7c7dff5ce6b1abba61cd213ff29` |
| sha256 `u2netp.pth` | `e7567cde013fb64813973ce6e1ecc25a80c05c3ca7adbc5a54f3c3d90991b854` |
| sha256 `u2netp.onnx` | `54569ac4932453abd7e64c2611ef66411fbc58dedb4b2e10251159bb63bfdb4c` |
| Converted on | 2026-10-14 |
| Command | `./tool/cutout_model/convert.sh` (docker, python:3.11-slim, PyTorch CPU, opset 17, input `input` 1x3x320x320, outputs `d0`..`d6`; `d0` is the final map, already through a sigmoid) |
| Runtime | `flutter_onnxruntime` 1.9.0 (MIT) over ONNX Runtime 1.28.0 (MIT) |

The ONNX file is not byte-reproducible across torch versions; the `.pth`
checksum is what the script checks.

Open (docs/SECURITY.md, legal): the weights were trained on DUTS-TR; no
licence on the weights beyond the repo's Apache-2.0 was found. A lawyer
should confirm before public release.
