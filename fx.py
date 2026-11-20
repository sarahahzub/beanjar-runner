#!/usr/bin/env python3
# Where is Chrome's own UI focus? Finds focus-ring blue pixels in the browser's top bars (y < YMAX) that are
# not blue in a baseline shot, and prints the largest cluster: "x=<center> w=<width> y=<y0>-<y1>" or "none".
#   fx.py BASE.png CUR.png [YMAX]
import sys
from PIL import Image

base, cur = Image.open(sys.argv[1]).convert("RGB"), Image.open(sys.argv[2]).convert("RGB")
ymax = int(sys.argv[3]) if len(sys.argv) > 3 else 118
W, H = cur.size
ymax = min(ymax, H)
bp, cp = base.load(), cur.load()


def blue(p):
    r, g, b = p
    return b > 170 and b - r > 70 and b - g > 45


cols = {}
for y in range(ymax):
    for x in range(W):
        if blue(cp[x, y]):
            # skip pixels that were blue in the baseline within 2 px
            if any(blue(bp[min(W - 1, max(0, x + dx)), min(H - 1, max(0, y + dy))]) for dx in (-2, 0, 2) for dy in (-2, 0, 2)):
                continue
            c = cols.setdefault(x, [0, y, y])
            c[0] += 1
            c[1] = min(c[1], y)
            c[2] = max(c[2], y)
runs, run = [], None
for x in sorted(cols):
    if run and x - run["x1"] <= 6:
        run["x1"] = x
        run["n"] += cols[x][0]
        run["y0"] = min(run["y0"], cols[x][1])
        run["y1"] = max(run["y1"], cols[x][2])
    else:
        run = {"x0": x, "x1": x, "n": cols[x][0], "y0": cols[x][1], "y1": cols[x][2]}
        runs.append(run)
runs = [r for r in runs if r["n"] >= 12]
if not runs:
    print("none")
else:
    r = max(runs, key=lambda r: r["n"])
    print(f"x={(r['x0'] + r['x1']) // 2} w={r['x1'] - r['x0'] + 1} y={r['y0']}-{r['y1']} n={r['n']}")
