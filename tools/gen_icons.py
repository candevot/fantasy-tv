#!/usr/bin/env python3
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os

FONT = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"
SIZES = {"mdpi":48,"hdpi":72,"xhdpi":96,"xxhdpi":144,"xxxhdpi":192}
C1=(0x5B,0x8C,0xFF); C2=(0x8E,0x6B,0xFF)
TEXT = "幻想"

def lerp(a,b,t): return int(a+(b-a)*t)

def mask(S,r):
    m=Image.new("L",(S,S),0); ImageDraw.Draw(m).rounded_rectangle([0,0,S-1,S-1],radius=r,fill=255); return m

def make(size):
    S=size*4
    grad=Image.new("RGBA",(S,S)); px=grad.load()
    for y in range(S):
        for x in range(S):
            t=y/S
            px[x,y]=(lerp(C1[0],C2[0],t),lerp(C1[1],C2[1],t),lerp(C1[2],C2[2],t),255)
    r=int(S*0.22); img=Image.new("RGBA",(S,S),(0,0,0,0)); img.paste(grad,(0,0),mask(S,r))
    # 顶部柔光
    g=Image.new("RGBA",(S,S),(0,0,0,0)); ImageDraw.Draw(g).ellipse([-S*0.4,-S*0.5,S*0.8,S*0.45],fill=(255,255,255,30))
    g=g.filter(ImageFilter.GaussianBlur(S*0.1)); img.alpha_composite(Image.composite(g,Image.new("RGBA",(S,S),(0,0,0,0)),mask(S,r)))
    # 文字：先画到独立层，按真实 bbox 精确居中
    f=ImageFont.truetype(FONT,int(S*0.34),index=2)  # SC
    layer=Image.new("RGBA",(S,S),(0,0,0,0)); ld=ImageDraw.Draw(layer)
    bbox=ld.textbbox((0,0),TEXT,font=f)
    tw,th=bbox[2]-bbox[0],bbox[3]-bbox[1]
    ld.text(((S-tw)/2-bbox[0],(S-th)/2-bbox[1]),TEXT,font=f,fill=(255,255,255,255))
    # 轻微投影
    sh=layer.filter(ImageFilter.GaussianBlur(S*0.012))
    img.alpha_composite(Image.composite(sh,Image.new("RGBA",(S,S),(0,0,0,0)),mask(S,r)).point(lambda v:int(v*0.25)) if False else sh)
    img.alpha_composite(layer)
    d=ImageDraw.Draw(img)
    d.rounded_rectangle([1,1,S-2,S-2],radius=r,outline=(255,255,255,55),width=max(2,int(S*0.004)))
    return img.resize((size,size),Image.LANCZOS)

os.makedirs("assets/icons",exist_ok=True)
for k,s in SIZES.items(): make(s).save(f"assets/icons/ic_launcher-{s}.png")
make(512).save("assets/icons/icon-512.png")
print("ok")
