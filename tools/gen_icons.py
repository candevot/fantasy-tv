#!/usr/bin/env python3
# 图标：渐变玻璃底 + 玻璃质感「幻」（白描边、流光、星点、投影）
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os, random, math

FONT = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"
SIZES = {"mdpi":48,"hdpi":72,"xhdpi":96,"xxhdpi":144,"xxxhdpi":192}
C1=(0x5B,0x8C,0xFF); C2=(0x8E,0x6B,0xFF)
TEXT="幻"

def lerp(a,b,t): return int(a+(b-a)*t)

def mask(S,r):
    m=Image.new("L",(S,S),0); ImageDraw.Draw(m).rounded_rectangle([0,0,S-1,S-1],radius=r,fill=255); return m

def star(d, cx, cy, r, alpha):
    pts=[(cx,cy-r),(cx+r*0.22,cy-r*0.22),(cx+r,cy),(cx+r*0.22,cy+r*0.22),(cx,cy+r),(cx-r*0.22,cy+r*0.22),(cx-r,cy),(cx-r*0.22,cy-r*0.22)]
    d.polygon(pts, fill=(255,255,255,alpha))

def make(size):
    S=size*4
    # 渐变底
    grad=Image.new("RGBA",(S,S)); px=grad.load()
    for y in range(S):
        for x in range(S):
            t=(x/S*0.35+y/S*0.65)
            px[x,y]=(lerp(C1[0],C2[0],t),lerp(C1[1],C2[1],t),lerp(C1[2],C2[2],t),255)
    r=int(S*0.22); img=Image.new("RGBA",(S,S),(0,0,0,0)); img.paste(grad,(0,0),mask(S,r))
    m=mask(S,r)
    # 顶部柔光
    g=Image.new("RGBA",(S,S),(0,0,0,0)); ImageDraw.Draw(g).ellipse([-S*0.45,-S*0.55,S*0.85,S*0.40],fill=(255,255,255,36))
    g=g.filter(ImageFilter.GaussianBlur(S*0.10)); img.alpha_composite(Image.composite(g,Image.new("RGBA",(S,S),(0,0,0,0)),m))
    # 磨砂颗粒
    noise=Image.new("RGBA",(S,S),(0,0,0,0)); nd=ImageDraw.Draw(noise)
    random.seed(7)
    for _ in range(int(S*S/900)):
        x=random.randint(0,S-1); y=random.randint(0,S-1)
        nd.point((x,y),fill=(255,255,255,random.randint(6,18)))
    img.alpha_composite(Image.composite(noise,Image.new("RGBA",(S,S),(0,0,0,0)),m))
    # 字层
    f=ImageFont.truetype(FONT,int(S*0.56),index=2)  # SC
    bbox=ImageDraw.Draw(Image.new("L",(1,1))).textbbox((0,0),TEXT,font=f)
    tw,th=bbox[2]-bbox[0],bbox[3]-bbox[1]
    tx,ty=(S-tw)/2-bbox[0],(S-th)/2-bbox[1]
    tmask=Image.new("L",(S,S),0); ImageDraw.Draw(tmask).text((tx,ty),TEXT,font=f,fill=255)
    # 投影
    sh=Image.new("RGBA",(S,S),(0,0,0,0)); sh.paste(Image.new("RGBA",(S,S),(20,30,60,150)),(0,0),tmask)
    sh=sh.filter(ImageFilter.GaussianBlur(S*0.02))
    img.alpha_composite(Image.composite(sh,Image.new("RGBA",(S,S),(0,0,0,0)),m).point(lambda v: v))
    # 字填充：白 → 淡蓝白 渐变
    fill=Image.new("RGBA",(S,S),(0,0,0,0)); fp=fill.load()
    for y in range(S):
        t=y/S
        fp_=(lerp(255,232,t),lerp(255,240,t),255,255)
        for x in range(S): fp[x,y]=fp_
    img.paste(fill,(0,0),tmask)
    # 流光带（裁剪在字内）
    sheen=Image.new("RGBA",(S,S),(0,0,0,0)); sd=ImageDraw.Draw(sheen)
    sd.polygon([(int(S*0.10),0),(int(S*0.42),0),(int(S*0.22),S),(int(-S*0.05),S)],fill=(255,255,255,90))
    sheen=sheen.filter(ImageFilter.GaussianBlur(S*0.015))
    img.paste(sheen,(0,0),tmask)
    # 白描边
    edge=Image.new("L",(S,S),0); ImageDraw.Draw(edge).text((tx,ty),TEXT,font=f,fill=255,stroke_width=max(2,int(S*0.006)),stroke_fill=255)
    edge=edge.filter(ImageFilter.GaussianBlur(S*0.002))
    edge=Image.eval(edge, lambda v: max(0, v-180))
    img.paste(Image.new("RGBA",(S,S),(255,255,255,120)),(0,0),edge)
    # 星点
    d=ImageDraw.Draw(img)
    random.seed(11)
    for _ in range(5):
        star(d, random.randint(int(S*0.08),int(S*0.92)), random.randint(int(S*0.08),int(S*0.92)), random.randint(int(S*0.012),int(S*0.026)), random.randint(90,170))
    # 内描边
    d.rounded_rectangle([1,1,S-2,S-2],radius=r,outline=(255,255,255,60),width=max(2,int(S*0.004)))
    return img.resize((size,size),Image.LANCZOS)

os.makedirs("assets/icons",exist_ok=True)
for k,s in SIZES.items(): make(s).save(f"assets/icons/ic_launcher-{s}.png")
make(512).save("assets/icons/icon-512.png")
print("ok")
