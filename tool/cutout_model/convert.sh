#!/bin/bash
# Converts the official U2-NetP weights to ONNX inside a container (the host
# has no Python). Provenance: tool/cutout_model/PROVENANCE.md.
set -euo pipefail

U2NET_COMMIT=ac7e1c817ecab7c7dff5ce6b1abba61cd213ff29
export U2NET_URL="https://raw.githubusercontent.com/xuebinqin/U-2-Net/$U2NET_COMMIT/model/u2net.py"
export WEIGHTS_GDRIVE_ID=1rbSTGKAE-MTxBYHd-51l2hMOQPT_7EPy
EXPECTED_PTH_SHA256=e7567cde013fb64813973ce6e1ecc25a80c05c3ca7adbc5a54f3c3d90991b854

cd "$(dirname "$0")/../.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/export.py" <<'PY'
import os
import urllib.request
import torch

urllib.request.urlretrieve(os.environ['U2NET_URL'], 'u2net.py')
from u2net import U2NETP
net = U2NETP(3, 1)
net.load_state_dict(torch.load('u2netp.pth', map_location='cpu'))
net.eval()
torch.onnx.export(net, torch.zeros(1, 3, 320, 320), 'u2netp.onnx', input_names=['input'], output_names=['d0','d1','d2','d3','d4','d5','d6'], opset_version=17, dynamo=False)
PY

docker run --rm --user "$(id -u):$(id -g)" -e HOME=/w -e U2NET_URL -e WEIGHTS_GDRIVE_ID -v "$WORK:/w" -w /w python:3.11-slim sh -c 'pip install -q --user gdown onnx numpy onnxscript >&2 && pip install -q --user --extra-index-url https://download.pytorch.org/whl/cpu torch >&2 && /w/.local/bin/gdown "$WEIGHTS_GDRIVE_ID" -O u2netp.pth >&2 && python export.py >&2'

pth_sha=$(sha256sum "$WORK/u2netp.pth" | cut -d' ' -f1)
if [ "$pth_sha" != "$EXPECTED_PTH_SHA256" ]; then
  echo "Error: u2netp.pth SHA256 mismatch" >&2
  exit 1
fi

mkdir -p assets/models
cp "$WORK/u2netp.onnx" assets/models/u2netp.onnx
onnx_sha=$(sha256sum assets/models/u2netp.onnx | cut -d' ' -f1)
echo "pth_sha=$pth_sha"
echo "onnx_sha=$onnx_sha"
echo "date=$(date -u +%F)"
