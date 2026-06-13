#!/usr/bin/env python3
"""Generate faithful CC Cost Monitor popover mockups with synthetic data.

Reproduces the SwiftUI popover layout/colors from Sources/Views.swift using the
same macOS system fonts the app renders with (SF, SF Rounded, SF Mono). Mock
data only — no real usage. Run: python3 docs/gen_mockups.py
"""
from PIL import Image, ImageDraw, ImageFont
import os, math

S = 2  # render scale (points -> px)
OUT = os.path.dirname(os.path.abspath(__file__))

SF      = "/System/Library/Fonts/SFNS.ttf"
ROUND   = "/System/Library/Fonts/SFNSRounded.ttf"
MONO    = "/System/Library/Fonts/SFNSMono.ttf"

def font(path, pt):  # pt in points
    return ImageFont.truetype(path, int(pt * S))

# ── palette (mirrors Views.swift) ──
FABLE  = (235, 140, 51)
OPUS   = (143, 69, 245)
SONNET = (61, 133, 250)
HAIKU  = (51, 199, 115)
GRAY   = (166, 166, 166)
BRAND  = (217, 119, 87)
TK_IN  = (26, 153, 166); TK_OUT = (230, 102, 77)
TK_CR  = (140, 199, 204); TK_CW = (235, 179, 158)
GH = [(235,237,240),(155,233,168),(64,196,99),(48,161,78),(33,110,57)]  # level 0..4 (light)

INK   = (40, 40, 42)
SUB   = (138, 138, 142)
FAINT = (170, 170, 174)
BG    = (244, 244, 246)
CARD  = (255, 255, 255)
LINE  = (228, 228, 231)

def canvas(w, h):
    img = Image.new("RGB", (int(w*S), int(h*S)), BG)
    return img, ImageDraw.Draw(img)

def rrect(d, xy, r, fill=None, outline=None, width=1):
    x0, y0, x1, y1 = xy
    if x1 <= x0 or y1 <= y0:
        return
    d.rounded_rectangle([c*S for c in (x0,y0,x1,y1)], radius=r*S, fill=fill, outline=outline,
                        width=max(1, int(width*S)))

def text(d, xy, s, fnt, fill=INK, anchor="la"):
    d.text((xy[0]*S, xy[1]*S), s, font=fnt, fill=fill, anchor=anchor)

def claude_logo(d, cx, cy, size, color):
    # simple sunburst glyph echoing the brand mark
    import math as m
    R = size/2
    for i in range(12):
        a = i * m.pi/6
        x1, y1 = cx + R*0.34*m.cos(a), cy + R*0.34*m.sin(a)
        x2, y2 = cx + R*m.cos(a), cy + R*m.sin(a)
        d.line([(x1*S,y1*S),(x2*S,y2*S)], fill=color, width=int(size*0.13*S))
    d.ellipse([((cx-R*0.30))*S,((cy-R*0.30))*S,((cx+R*0.30))*S,((cy+R*0.30))*S], fill=color)

def header(d, w, active):
    # logo + title
    claude_logo(d, 22, 26, 18, BRAND)
    text(d, (40, 17), "Local CC Usage", font(SF, 15), INK)
    # tab segmented control
    tabs = ["Cost", "Tokens", "Time", "Plan"]
    tw = (w - 24) / len(tabs)
    y0, y1 = 46, 72
    rrect(d, (12, y0, w-12, y1), 7, fill=(232,232,235))
    for i, t in enumerate(tabs):
        x0 = 12 + i*tw
        if t == active:
            rrect(d, (x0+2, y0+2, x0+tw-2, y1-2), 6, fill=CARD)
            text(d, (x0+tw/2, (y0+y1)/2), t, font(SF, 12.5), INK, anchor="mm")
        else:
            text(d, (x0+tw/2, (y0+y1)/2), t, font(SF, 12.5), SUB, anchor="mm")

def footer(d, w, y):
    d.line([(12*S, y*S), ((w-12)*S, y*S)], fill=LINE, width=S)
    text(d, (16, y+10), "Updated just now", font(SF, 10.5), SUB)
    # right icons (globe / refresh / power) as simple glyphs
    for i, gx in enumerate([w-66, w-42, w-20]):
        d.ellipse([(gx-7)*S,(y+8)*S,(gx+7)*S,(y+22)*S], outline=SUB, width=S)

# ── proportion bar ──
def prop_bar(d, x, y, w, segs, h=6, r=3):
    rrect(d, (x, y, x+w, y+h), r, fill=(236,236,238))
    cx = x
    total = sum(f for _,f in segs) or 1
    for color, frac in segs:
        seg_w = w*frac/total
        if seg_w > 1:
            rrect(d, (cx, y, cx+seg_w-1.5, y+h), r, fill=color)
        cx += seg_w

# ════════════════════════════════════════════════ COST TAB
def cost_tab():
    w, h = 300, 480
    img, d = canvas(w, h)
    header(d, w, "Cost")
    # month nav
    text(d, (w/2, 90), "‹     May 2026     ›", font(SF, 12.5), INK, anchor="mm")
    # monthly total card
    rrect(d, (12, 104, w-12, 250), 10, fill=CARD, outline=LINE)
    text(d, (26, 116), "Monthly Total", font(SF, 12.5), SUB)
    text(d, (w-26, 132), "$5,847", font(ROUND, 26), INK, anchor="ra")
    models = [("Opus", OPUS, 5612.40, 0.96), ("Sonnet", SONNET, 198.30, 0.034),
              ("Haiku", HAIKU, 36.50, 0.006)]
    prop_bar(d, 26, 162, w-52, [(c,f) for _,c,_,f in models], h=7, r=3.5)
    yy = 178
    for name, c, val, _ in models:
        d.ellipse([26*S,(yy+3)*S,32*S,(yy+9)*S], fill=c)
        text(d, (38, yy), name, font(SF, 11.5), INK)
        text(d, (w-26, yy), f"${val:,.2f}", font(MONO, 11), INK, anchor="ra")
        yy += 17
    text(d, (26, yy+6), "18,402 msgs   ·   3,318.4m tokens", font(SF, 11), SUB)
    # daily chart card
    rrect(d, (12, 266, w-12, h-40), 10, fill=CARD, outline=LINE)
    text(d, (26, 276), "Daily", font(SF, 10.5), SUB)
    bars = [3,5,16,77,20,12,38,355,295,420,210,180,498,520,470,90,260,120,180,90,
            60,63,46,74,37,48,215,330,233,54,290]
    bx, by, bw, bh = 26, 296, w-52, 128
    mx = max(bars)
    step = bw/len(bars)
    today = len(bars)-1
    for i, v in enumerate(bars):
        bhh = max(2, v/mx*bh)
        x0 = bx + i*step
        col = BRAND if i==today else (BRAND[0],BRAND[1],BRAND[2])
        fill = col if i==today else tuple(int(c*0.8+255*0.2) for c in BRAND)
        rrect(d, (x0, by+bh-bhh, x0+step-1.2, by+bh), 1.5, fill=fill)
    for lbl, i in [("1",0),("5",4),("10",9),("15",14),("20",19),("25",24),("31",30)]:
        text(d, (bx+i*step+step/2, by+bh+6), lbl, font(SF, 8), FAINT, anchor="ma")
    footer(d, w, h-30)
    img.save(f"{OUT}/cost.png")
    print("wrote cost.png")

# ════════════════════════════════════════════════ TOKENS TAB
def tokens_tab():
    w, h = 300, 376
    img, d = canvas(w, h)
    header(d, w, "Tokens")
    text(d, (w/2, 90), "‹     May 2026     ›", font(SF, 12.5), INK, anchor="mm")
    rrect(d, (12, 104, w-12, 266), 10, fill=CARD, outline=LINE)
    text(d, (26, 116), "Monthly Total", font(SF, 12.5), SUB)
    text(d, (w-26, 120), "3,318m", font(ROUND, 24), INK, anchor="ra")
    # token type bar
    segs = [(TK_IN,0.08),(TK_OUT,0.05),(TK_CR,0.74),(TK_CW,0.13)]
    prop_bar(d, 26, 150, w-52, segs, h=8, r=4)
    legend = [("in",TK_IN,"265m"),("out",TK_OUT,"166m"),("c_r",TK_CR,"2.46b"),("c_w",TK_CW,"431m")]
    lx = 26
    for name, c, val in legend:
        d.ellipse([lx*S,167*S,(lx+5)*S,172*S], fill=c)
        text(d, (lx+9, 164), name, font(SF, 9), tuple(int(v*0.9) for v in c))
        text(d, (lx+9, 176), val, font(MONO, 9), SUB)
        lx += 64
    # per-model
    yy = 200
    text(d, (26, yy), "By model", font(SF, 10.5), SUB); yy += 18
    for name, c, val in [("Opus",OPUS,"3,140m"),("Sonnet",SONNET,"152m"),("Haiku",HAIKU,"26m")]:
        d.ellipse([26*S,(yy+3)*S,32*S,(yy+9)*S], fill=c)
        text(d, (38, yy), name, font(SF, 11.5), INK)
        text(d, (w-26, yy), val, font(MONO, 11), INK, anchor="ra")
        yy += 18
    footer(d, w, h-30)
    img.save(f"{OUT}/tokens.png")
    print("wrote tokens.png")

# ════════════════════════════════════════════════ PLAN TAB
def plan_tab():
    w, h = 300, 352
    img, d = canvas(w, h)
    header(d, w, "Plan")
    text(d, (26, 92), "Remaining quota", font(SF, 13), INK)
    rows = [("5-hour window", 0.62, "2h 14m", HAIKU),
            ("7-day · all models", 0.38, "4d 9h", HAIKU),
            ("7-day · Sonnet", 0.81, "5d 2h", (235,170,60))]
    yy = 120
    for label, used, reset, col in rows:
        rrect(d, (12, yy, w-12, yy+58), 10, fill=CARD, outline=LINE)
        text(d, (26, yy+12), label, font(SF, 12), INK)
        text(d, (w-26, yy+12), f"{int((1-used)*100)}% left", font(ROUND, 13), col, anchor="ra")
        rrect(d, (26, yy+34, w-26, yy+42), 4, fill=(236,236,238))
        rrect(d, (26, yy+34, 26+(w-52)*used, yy+42), 4, fill=col)
        text(d, (26, yy+45), f"{int(used*100)}% used", font(SF, 9.5), SUB)
        text(d, (w-26, yy+45), f"resets in {reset}", font(SF, 9.5), SUB, anchor="ra")
        yy += 66
    footer(d, w, h-30)
    img.save(f"{OUT}/plan.png")
    print("wrote plan.png")

# ════════════════════════════════════════════════ TIME — WEEK
def time_week():
    w, h = 400, 384
    img, d = canvas(w, h)
    header(d, w, "Time")
    # sub-segmented Week/Month/Year
    subs = ["Week","Month","Year"]; sw=(w-24)/3
    rrect(d, (12, 84, w-12, 106), 6, fill=(232,232,235))
    for i,t in enumerate(subs):
        x0=12+i*sw
        if t=="Week":
            rrect(d,(x0+2,86,x0+sw-2,104),5,fill=CARD)
            text(d,(x0+sw/2,95),t,font(SF,11.5),INK,anchor="mm")
        else:
            text(d,(x0+sw/2,95),t,font(SF,11.5),SUB,anchor="mm")
    rrect(d, (12, 116, w-12, h-40), 10, fill=CARD, outline=LINE)
    # summary
    for i,(lab,val) in enumerate([("Week total","26h 18m"),("Daily avg","3h 45m"),("Longest","3h 22m")]):
        x=28+i*120
        text(d,(x,128),lab,font(SF,9),SUB)
        text(d,(x,140),val,font(ROUND,13),INK)
    # 7 rows Mon-Sun, x-axis 0-24h, model-colored capsules
    days = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
    # each: list of (start_h, end_h, color)
    sched = [
        [(9.2,10.1,OPUS),(10.4,12.0,OPUS),(14.1,16.3,SONNET),(21.0,22.4,OPUS)],
        [(8.8,9.2,HAIKU),(9.5,12.6,OPUS),(13.5,14.0,GRAY),(15.0,18.1,OPUS),(20.5,21.0,SONNET)],
        [(10.0,10.3,GRAY),(11.0,13.2,OPUS),(14.0,17.5,OPUS),(22.0,23.1,SONNET)],
        [(9.0,9.1,GRAY),(9.6,12.0,OPUS),(13.0,13.4,HAIKU),(14.2,19.0,OPUS)],
        [(8.5,9.0,SONNET),(9.3,11.5,OPUS),(13.0,16.8,OPUS),(17.2,17.5,GRAY),(21.5,23.4,OPUS)],
        [(11.0,12.5,OPUS),(15.3,16.0,HAIKU)],
        [(20.0,20.4,SONNET),(21.0,22.8,OPUS)],
    ]
    rx0, rw = 56, w-56-50
    ry = 160; rh = 18
    grid_h = [0,6,12,18,24]
    for di, day in enumerate(days):
        cy = ry + di*(rh+4)
        is_today = di==4
        if is_today:
            rrect(d,(16,cy-1,w-16,cy+rh+1),4,fill=(247,247,249))
        text(d,(50,cy+rh/2),day,font(SF,9),(INK if is_today else SUB),anchor="rm")
        # gridlines
        for gh in grid_h:
            gx = rx0 + rw*gh/24
            d.line([(gx*S,cy*S),(gx*S,(cy+rh)*S)],fill=(238,238,240),width=S)
        # capsules
        total=0
        for (s,e,col) in sched[di]:
            total += e-s
            x0 = rx0 + rw*s/24
            x1 = rx0 + rw*e/24
            cap_y = cy + rh/2 - 4
            rrect(d,(x0,cap_y,max(x1,x0+1.5),cap_y+8), 4, fill=col)
        text(d,(w-20,cy+rh/2),f"{int(total)}h {int((total%1)*60):02d}m",font(MONO,8.5),
             (INK if total>0 else FAINT),anchor="rm")
    # hour axis
    ay = ry+7*(rh+4)+2
    for gh in grid_h:
        gx = rx0 + rw*gh/24
        text(d,(gx,ay),str(gh),font(SF,8),FAINT,anchor="ma")
    footer(d, w, h-30)
    img.save(f"{OUT}/time-week.png")
    print("wrote time-week.png")

# ════════════════════════════════════════════════ TIME — YEAR (heatmap)
def time_year():
    w, h = 400, 250
    img, d = canvas(w, h)
    header(d, w, "Time")
    subs = ["Week","Month","Year"]; sw=(w-24)/3
    rrect(d, (12, 84, w-12, 106), 6, fill=(232,232,235))
    for i,t in enumerate(subs):
        x0=12+i*sw
        if t=="Year":
            rrect(d,(x0+2,86,x0+sw-2,104),5,fill=CARD)
            text(d,(x0+sw/2,95),t,font(SF,11.5),INK,anchor="mm")
        else:
            text(d,(x0+sw/2,95),t,font(SF,11.5),SUB,anchor="mm")
    rrect(d, (12, 116, w-12, h-40), 10, fill=CARD, outline=LINE)
    text(d, (w/2, 128), "‹     2026     ›", font(SF, 12), INK, anchor="mm")
    # 53 cols x 7 rows heatmap with a plausible activity pattern
    import random
    rng = random.Random(7)
    cell, gap = 5, 1.6
    gx0, gy0 = 28, 150
    levels = []
    for c in range(53):
        col=[]
        # ramp up activity through the year, weekends lighter
        base = 0.15 + 0.6*(c/53)
        for r in range(7):
            weekend = 0.4 if r>=5 else 1.0
            x = rng.random()
            v = base*weekend - 0.1
            if c < 14: v *= 0.3   # before user started (sparse)
            lvl = 0
            if x < v*0.4: lvl=1
            if x < v*0.25: lvl=2
            if x < v*0.13: lvl=3
            if x < v*0.06: lvl=4
            col.append(lvl)
        levels.append(col)
    for c in range(53):
        for r in range(7):
            x0 = gx0 + c*(cell+gap); y0 = gy0 + r*(cell+gap)
            rrect(d,(x0,y0,x0+cell,y0+cell),1.3,fill=GH[levels[c][r]])
    # month labels
    months=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
    for mi,mn in enumerate(months):
        gx = gx0 + (mi*53/12)*(cell+gap)
        text(d,(gx,gy0-12),mn,font(SF,7.5),FAINT)
    # legend
    ly = gy0+7*(cell+gap)+8
    text(d,(w-150,ly),"Less",font(SF,8.5),SUB)
    for i in range(5):
        x0=w-118+i*12
        rrect(d,(x0,ly,x0+8,ly+8),1.3,fill=GH[i])
    text(d,(w-50,ly),"More",font(SF,8.5),SUB)
    footer(d, w, h-30)
    img.save(f"{OUT}/time-year.png")
    print("wrote time-year.png")

if __name__ == "__main__":
    cost_tab(); tokens_tab(); plan_tab(); time_week(); time_year()
    print("done")
