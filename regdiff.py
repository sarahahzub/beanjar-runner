#!/usr/bin/env python3
# regdiff.py A.png B.png [X0 Y0 X1 Y1]: share of pixels that differ clearly between two screenshots in a region
# (default: the lower 40 %, where LG's on-screen keyboard appears), and the box of the changed pixels.
import sys
from PIL import Image, ImageChops

a = Image.open(sys.argv[1]).convert("RGB")
b = Image.open(sys.argv[2]).convert("RGB").resize(a.size)
w, h = a.size
box = tuple(int(v) for v in sys.argv[3:7]) if len(sys.argv) >= 7 else (0, int(h * 0.6), w, h)
d = ImageChops.difference(a.crop(box), b.crop(box)).convert("L").point(lambda v: 255 if v > 40 else 0)
n = sum(1 for v in d.getdata() if v)
bb = d.getbbox()
if bb:
    bb = (bb[0] + box[0], bb[1] + box[1], bb[2] + box[0], bb[3] + box[1])
print("share=%.4f box=%s" % (n / float((box[2] - box[0]) * (box[3] - box[1])), ",".join(map(str, bb)) if bb else "none"))
