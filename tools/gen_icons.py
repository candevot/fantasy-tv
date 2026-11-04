#!/usr/bin/env python3
# 生成与启动动画一致的图标：渐变圆角方块 + 白色「幻」+ 斜向高光
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os, math

FONT = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"
SIZES = {"mdpi":48,"hdpi":72,"xhdpi":96,"xxhdpi":144,"xxxhdpi":192}

def lerp(a,b,t): return int(a+(b-a)*t)

def make(size):
    S = size*4  # 超采样
    img = Image.new("RGBA",(S,S),(0,0,0,0))
    d = ImageDraw.Draw(img)
    r = int(S*0.22)
    # 渐变底
    grad = Image.new("RGBA",(S,S))
    gd = ImageDraw.Draw(grad)
    c1=(0x5B,0x8C,0xFF); c2=(0x8E,0x6B,0xFF)
    for y in range(S):
        t=y/S
        for x in range(0,S,1):
            tt=(t*0.7 + (x/S)*0.3)
            gd.point((x,y), fill=(lerp(c1[0],c2[0],tt), lerp(c1[1],c2[1],tt), lerp(c1[2],c2[2],tt),255))
    mask = Image.new("L",(S,S),0)
    ImageDraw.Draw(mask).rounded_rectangle([0,0,S-1,S-1], radius=r, fill=255)
    img.paste(grad,(0,0),mask)
    # 斜向高光
    hi = Image.new("RGBA",(S,S),(0,0,0,0))
    hd = ImageDraw.Draw(hi)
    hd.polygon([(0,int(S*0.05)),(int(S*0.75),0),(int(S*0.35),S),(0,int(S*0.75))], fill=(255,255,255,42))
    hi = hi.filter(ImageFilter.GaussianBlur(S*0.02))
    img.alpha_composite(Image.composite(hi, Image.new("RGBA",(S,S),(0,0,0,0)), mask))
    # 「幻」字
    f = ImageFont.truetype(FONT, int(S*0.60))
    bbox = d.textbbox((0,0),"幻",font=f)
    tw,th = bbox[2]-bbox[0], bbox[3]-bbox[1]
    d.text(((S-tw)/2-bbox[0], (S-th)/2-bbox[1]), "幻", font=f, fill=(255,255,255,255))
    # 内描边
    d.rounded_rectangle([1,1,S-2,S-2], radius=r, outline=(255,255,255,60), width=max(2,int(S*0.004)))
    return img.resize((size,size), Image.LANCZOS)

os.makedirs("assets/icons", exist_ok=True)
for k,s in SIZES.items():
    make(s).save(f"assets/icons/ic_launcher-{s}.png")
make(512).save("assets/icons/icon-512.png")
print("ok", os.listdir("assets/icons"))
