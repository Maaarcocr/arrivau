#!/usr/bin/env python3
"""Build the original geometric Arrivau pilot icon (requires Pillow)."""
from pathlib import Path
from PIL import Image, ImageDraw
SCALE = 3
im = Image.new('RGB', (1024 * SCALE, 1024 * SCALE), '#173F35')
draw = ImageDraw.Draw(im)
def line(points, fill, width):
    draw.line([(x*SCALE,y*SCALE) for x,y in points], fill=fill, width=width*SCALE, joint='curve')
def circle(x,y,r,fill):
    draw.ellipse(((x-r)*SCALE,(y-r)*SCALE,(x+r)*SCALE,(y+r)*SCALE), fill=fill)
# A bent delivery route and its destination marker; original vector-like artwork.
line([(265,740),(440,310),(585,310),(760,740)], '#F8F4E6', 85)
line([(365,555),(664,555)], '#F8F4E6', 80)
circle(265,740,65,'#F4AA46')
circle(760,740,65,'#F4AA46')
circle(512,310,90,'#F4AA46')
circle(512,310,32,'#173F35')
im.resize((1024,1024), Image.Resampling.LANCZOS).save(Path(__file__).resolve().parents[1]/'ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png')
