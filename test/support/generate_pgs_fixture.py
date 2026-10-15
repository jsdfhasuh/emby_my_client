"""Synthetic public-data-only PGS/MJPEG/PCM fixture. No private media.
PGS segment encoding follows FFmpeg n6.0 libavcodec/pgssubdec.c.
"""
from pathlib import Path
import sys, struct, io, hashlib, json
root=Path(__file__).resolve().parents[1]/'fixtures/subtitles'
root.mkdir(parents=True,exist_ok=True)

from PIL import Image,ImageDraw,ImageFont
W,H=320,180
def num(n): return n.to_bytes(max(1,(n.bit_length()+7)//8),'big')
def el(id,b):
 width=next(w for w in range(1,9) if len(b)<(1<<(7*w))-1)
 return num(id)+(len(b)|(1<<(7*width))).to_bytes(width,'big')+b
def ui(id,n): return el(id,num(n))
def st(id,s): return el(id,s.encode())
def fl(id,x): return el(id,struct.pack('>d',x))
def seg(t,b): return bytes([t])+struct.pack('>H',len(b))+b
def pgs(text,epoch):
 image=Image.new('1',(180,24)); d=ImageDraw.Draw(image)
 d.text((3,3),text,font=ImageFont.load_default(size=18),fill=1)
 (root/('expected-'+text.replace(' ','-')+'.mask')).write_bytes(bytes(1 if p else 0 for p in image.getdata()))
 # Literal nonzero pixels; transparent runs use zero + 6-bit length.
 rle=bytearray()
 for y in range(image.height):
  x=0
  while x<image.width:
   if image.getpixel((x,y)): rle.append(1); x+=1
   else:
    n=1
    while x+n<image.width and n<63 and not image.getpixel((x+n,y)): n+=1
    rle.extend([0,n]);x+=n
  rle.extend([0,0])
 pcs=struct.pack('>HHBHBBBBHBBHH',W,H,0x10,epoch,0x80,0,0,1,0,0,0,70,140)
 wds=struct.pack('>BBHHHH',1,0,70,140,image.width,image.height)
 pds=bytes([0,0,0,16,128,128,0,1,235,128,128,255])
 ods=bytes([0,0,0,0xc0])+(len(rle)+4).to_bytes(3,'big')+struct.pack('>HH',image.width,image.height)+rle
 return seg(0x16,pcs)+seg(0x17,wds)+seg(0x14,pds)+seg(0x15,ods)+seg(0x80,b'')
video=io.BytesIO(); Image.new('RGB',(W,H),(0,0,0)).save(video,format='JPEG',quality=90)
v=video.getvalue()
tracks=el(0xae,ui(0xd7,1)+ui(0x73c5,1)+ui(0x83,1)+st(0x86,'V_MJPEG')+ui(0x23e383,500000000)+el(0xe0,ui(0xb0,W)+ui(0xba,H)))
tracks+=el(0xae,ui(0xd7,2)+ui(0x73c5,2)+ui(0x83,2)+st(0x86,'A_PCM/INT/LIT')+el(0xe1,fl(0xb5,8000)+ui(0x9f,1)+ui(0x6264,16)))
for i,label in enumerate(['PGS ALPHA','PGS BETA']):
 tracks+=el(0xae,ui(0xd7,i+3)+ui(0x73c5,i+3)+ui(0x83,17)+ui(0x88,0)+st(0x86,'S_HDMV/PGS')+st(0x536e,label)+st(0x22b59c,'eng'))
ass_header = '[Script Info]\nScriptType: v4.00+\nPlayResX: 320\nPlayResY: 180\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
tracks+=el(0xae,ui(0xd7,5)+ui(0x73c5,5)+ui(0x83,17)+ui(0x88,0)+st(0x86,'S_TEXT/ASS')+st(0x536e,'TEXT')+st(0x22b59c,'eng')+st(0x63a2,ass_header))
clusters=b''
for second in range(12):
 b=ui(0xe7,second*1000)
 b+=el(0xa0,el(0xa1,bytes([0x85,0,0,0])+f'{second},0,Default,,0,0,0,,TEXT_CUE'.encode())+ui(0x9b,1000))
 for i,label in enumerate(['PGS ALPHA','PGS BETA']):
  b+=el(0xa0,el(0xa1,bytes([0x83+i,0,0,0])+pgs(label,second))+ui(0x9b,1000))
 b+=el(0xa3,bytes([0x82,0,0,0x80])+bytes(16000))
 for ms in [0,500]: b+=el(0xa3,bytes([0x81])+struct.pack('>h',ms)+b'\x80'+v)
 clusters+=el(0x1f43b675,b)
header=el(0x1a45dfa3,ui(0x4286,1)+ui(0x42f7,1)+ui(0x42f2,4)+ui(0x42f3,8)+st(0x4282,'matroska')+ui(0x4287,4)+ui(0x4285,2))
data=header+el(0x18538067,el(0x1549a966,ui(0x2ad7b1,1000000)+fl(0x4489,12000)+st(0x4d80,'self-generated-pgs')+st(0x5741,'self-generated-pgs'))+el(0x1654ae6b,tracks)+clusters)
(root/'synthetic-pgs.mkv').write_bytes(data)
manifest={'file':'synthetic-pgs.mkv','sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'tracks':['MJPEG black 320x180','PCM silence 8000Hz','PGS ALPHA image','PGS BETA image','ASS TEXT_CUE'],'source':'Generated from code only. No user media or downloads.'}
(root/'fixture-manifest.json').write_text(json.dumps(manifest,indent=2))
print(json.dumps(manifest,indent=2))


(root/'external.srt').write_text('1\n00:00:00,000 --> 00:00:12,000\nEXTERNAL_CUE\n',encoding='utf-8')
