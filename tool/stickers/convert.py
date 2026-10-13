"""Turns tool/stickers/noto/starter_NN.png (Noto Color Emoji, Apache 2.0) into assets/stickers/starter_NN.webp
(512x512, transparent, at most 100 KB) and writes the owner's preview page.

Run in a container (see tool/stickers/convert.sh); needs pillow.
"""
import base64
import io
import pathlib
import sys

from PIL import Image

SRC = pathlib.Path(sys.argv[1])
OUT = pathlib.Path(sys.argv[2])
PAGE = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else None
MAX_BYTES = 100 * 1024

OUT.mkdir(parents=True, exist_ok=True)
cards = []
for svg in sorted(SRC.glob("starter_*.png")):
    image = Image.open(svg).convert("RGBA")
    assert image.size == (512, 512), svg
    data = b""
    for quality in (90, 80, 70, 60, 50):
        buf = io.BytesIO()
        image.save(buf, "WEBP", quality=quality, method=6)
        data = buf.getvalue()
        if len(data) <= MAX_BYTES:
            break
    assert len(data) <= MAX_BYTES, f"{svg.name}: {len(data)} bytes"
    (OUT / (svg.stem + ".webp")).write_bytes(data)
    print(f"{svg.stem}.webp {len(data)} bytes")
    cards.append((svg.stem, len(data), base64.b64encode(data).decode()))

if PAGE is not None:
    PAGE.parent.mkdir(parents=True, exist_ok=True)
    items = "".join(
        f'<figure><img src="data:image/webp;base64,{b64}" width="160" height="160">'
        f"<figcaption>{name} ({size // 1024} KB)</figcaption></figure>"
        for name, size, b64 in cards
    )
    PAGE.write_text(
        "<!doctype html><meta charset=utf-8><title>SIS starter stickers</title>"
        "<style>body{font-family:sans-serif;background:#f4f1ea;margin:24px}"
        "main{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;max-width:760px}"
        "figure{margin:0;text-align:center;background:#fff;border-radius:16px;padding:12px}"
        "figcaption{font-size:12px;color:#666}.dark figure{background:#1d1d22}</style>"
        "<h1>SIS starter stickers</h1><p>16 stickers, 512x512 WebP, at most 100 KB each.</p>"
        f"<main>{items}</main>"
        "<h2>On a dark chat</h2><main class=dark>"
        f"{items}</main>"
    )
