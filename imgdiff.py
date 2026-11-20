#!/usr/bin/env python3
# Fraction of pixels that differ (any channel by more than 40) between two screenshots: imgdiff.py A.png B.png
import sys
from PIL import Image, ImageChops

a, b = (Image.open(p).convert("RGB") for p in sys.argv[1:3])
if a.size != b.size:
    print("1.0")
    raise SystemExit
d = ImageChops.difference(a, b).convert("L").point(lambda v: 255 if v > 40 else 0)
print(f"{d.histogram()[255] / (a.size[0] * a.size[1]):.5f}")
