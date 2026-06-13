#!/usr/bin/env python3
"""Post-process: SwiftUI Buttons (week/year nav chevrons) bridge to NSButton and
render as a yellow (255,204,0) placeholder under off-screen ImageRenderer. Erase
those boxes and paint clean gray chevrons in their place. Idempotent.
"""
from PIL import Image, ImageDraw
import sys, os

YELLOW = (255, 204, 0)
# EXACT placeholder yellow only — the amber subscription bar (~235,170,60) must
# not match, or we'd erase a real chart element.
def is_y(p): return p[0] >= 252 and 200 <= p[1] <= 208 and p[2] <= 4

def clusters(xs):
    xs = sorted(set(xs)); out = []; cur = [xs[0]]
    for v in xs[1:]:
        if v - cur[-1] <= 25: cur.append(v)
        else: out.append((cur[0], cur[-1])); cur = [v]
    out.append((cur[0], cur[-1])); return out

def fix(path):
    im = Image.open(path).convert("RGB"); W, H = im.size; px = im.load()
    ys = [(x, y) for y in range(H) for x in range(W) if is_y(px[x, y])]
    if not ys: return False
    yall = [y for _, y in ys]; xall = [x for x, _ in ys]
    y0, y1 = min(yall), max(yall)
    d = ImageDraw.Draw(im)
    for cx0, cx1 in clusters(xall):
        # bg sampled just above the box
        bg = px[(cx0+cx1)//2, max(0, y0-6)]
        d.rectangle([cx0-3, y0-3, cx1+3, y1+3], fill=bg)
        cx, cy = (cx0+cx1)//2, (y0+y1)//2
        s = max(5, (y1-y0)//4)              # chevron half-size
        col = (120, 120, 124); wd = max(2, s//4)
        left = cx < W//2
        tip = cx - s if left else cx + s
        back = cx + s if left else cx - s
        d.line([(back, cy-s), (tip, cy), (back, cy+s)], fill=col, width=wd, joint="curve")
    im.save(path); return True

if __name__ == "__main__":
    base = sys.argv[1] if len(sys.argv) > 1 else "docs"
    # Only the week & year sub-views have nav Buttons; never touch the others.
    for n in ("time-week", "time-year"):
        p = os.path.join(base, n + ".png")
        if os.path.exists(p) and fix(p): print("fixed nav in", n)
