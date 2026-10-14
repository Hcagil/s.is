# Bundled cut-out model: provenance

`assets/models/u2netp.tflite` is the Android-only on-phone fallback for sticker cut-out (used when ML Kit is unavailable or returns no mask, e.g. phones with microG). Bundled, never downloaded at runtime. iOS uses Apple Vision only.

| Item | Value |
|------|-------|
| Model | U2-NetP (https://github.com/xuebinqin/U-2-Net), Apache-2.0 |
| Source of weights | official `u2netp.pth`, Google Drive id `1rbSTGKAE-MTxBYHd-51l2hMOQPT_7EPy` (linked from the repo README) |
| Model code | `model/u2net.py` at commit `ac7e1c817ecab7c7dff5ce6b1abba61cd213ff29` |
| sha256 `u2netp.pth` | `e7567cde013fb64813973ce6e1ecc25a80c05c3ca7adbc5a54f3c3d90991b854` |
| sha256 `u2netp.onnx` (intermediate, not shipped) | `54569ac4932453abd7e64c2611ef66411fbc58dedb4b2e10251159bb63bfdb4c` (opset 17) |
| sha256 `u2netp.tflite` (fp32, shipped, 4,575,000 bytes) | `9efc3dd3ac355586697a4022a24cde050b2da1a67a3c55f2adb3087c59bf75fa` |
| fp16 variant (not shipped, 2,351,676 bytes) | sha256 `d6a33d3b775ef8bef7abe7121befb694b7d2ee134990d6f252f12aecbda96828` |
| Converted on | 2026-10-14 |
| Command | `./tool/cutout_model/convert.sh` (docker python:3.11-slim). Stage 1: PyTorch to ONNX (input `input` 1x3x320x320, output `d0`, already through a sigmoid). Stage 2, `tool/cutout_model/to_tflite.py`: ONNX trimmed to output d0 with `onnx.utils.extract_model`, then onnx2tf 1.29.24 with tensorflow-cpu 2.19.0, tf_keras 2.19.0, onnx 1.19.1, onnxruntime 1.23.0, ai-edge-litert 2.1.0, numpy 1.26.4, onnxsim 0.4.36. Full `pip freeze`: `tool/cutout_model/tflite-freeze.txt`. |
| TFLite layout | input float32 NHWC 1x320x320x3 (ImageNet-normalised RGB, interleaved); one output float32 NHWC 1x320x320x1 = d0 probabilities |
| Runtime | `com.google.ai.edge.litert:litert` 2.3.0 from Google Maven (Apache-2.0; standalone, not the Play-services variant), Android only |

## Numeric check (ONNX Runtime vs TFLite, d0, max abs difference)

Three synthetic inputs (bright disc, random noise, gradient; not photographs). fp32: 3.6e-05, 3.6e-06, 1.1e-06. fp16 (not used): 2.8e-02, 7.8e-03, 1.9e-04. onnx2tf's built-in self-check sample file is replaced by a local random file, because its download fails.

Open (docs/SECURITY.md, legal): the weights were trained on DUTS-TR; no licence on the weights beyond the repo's Apache-2.0 was found. A lawyer should confirm before public release.
