from pathlib import Path
import urllib.request, concurrent.futures, subprocess, json, hashlib, shutil
r=Path(__file__).resolve().parents[1]; f=r/'Demo/Fixtures';f.mkdir(parents=True,exist_ok=True)
import os
ff=os.environ.get('FFMPEG_BIN') or shutil.which('ffmpeg')
if not ff: raise SystemExit('Set FFMPEG_BIN to an existing ffmpeg executable.')
probe=os.environ.get('FFPROBE_BIN') or str(Path(ff).with_name('ffprobe'))
urls={
'photoprism-tsu-hevc.mp4':'https://dl.photoprism.app/samples/Formats/Video/H.265-HEVC/TSU_1280x720.mp4',
'internet-h264.mp4':'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4',
'internet-hevc.mp4':'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h265/360/Big_Buck_Bunny_360_10s_1MB.mp4',
}
for required in ['sample.mp4','internet-vp9.webm']:
 if not (f/required).is_file():
  raise SystemExit('Restore the local Demo/Fixtures/'+required+' fixture before preparing test media.')
def download(kv):
 name,url=kv;path=f/name
 if not path.exists():
  with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'}),timeout=40) as res: data=res.read(6*1024*1024)
  path.write_bytes(data)
 return name,url
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool: rows=list(pool.map(download,urls.items()))
def run(args):
 out=subprocess.run([ff,'-hide_banner','-loglevel','error','-y']+args,capture_output=True,text=True,timeout=75)
 if out.returncode: raise RuntimeError(str(args)+out.stderr)
base=['-i',str(f/'sample.mp4')]
for name,args in {
'h264.mov':['-c','copy'], 'h264.mkv':['-c','copy'], 'h264.ts':['-c','copy','-f','mpegts'],
'h264.flv':['-c','copy','-f','flv'], 'audio.m4a':['-vn','-c:a','copy'],
'raw.h264':['-an','-c:v','copy','-bsf:v','h264_mp4toannexb','-f','h264']}.items(): run(base+args+[str(f/name)])
run(['-i',str(f/'internet-hevc.mp4'),'-an','-c:v','copy','-bsf:v','hevc_mp4toannexb','-f','hevc',str(f/'raw.h265')])
for folder,source,kind in [('hls-ts','sample.mp4','mpegts'),('hls-fmp4','sample.mp4','fmp4'),('hls-hevc','internet-hevc.mp4','fmp4')]:
 d=f/folder;d.mkdir(exist_ok=True)
 run(['-i',str(f/source),'-c','copy','-f','hls','-hls_time','2','-hls_list_size','0','-hls_segment_type',kind,'-hls_segment_filename',str(d/('segment%d.'+('ts' if kind=='mpegts' else 'm4s'))),str(d/'index.m3u8')])
 # Segment keyframes from source may be farther apart than target duration.
 master='#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000\nindex.m3u8\n'
 (d/'master.m3u8').write_text(master)
run(base+['-c','copy','-movflags','+faststart',str(f/'faststart.mp4')])
run(base+['-t','6','-vf','scale=848:480','-an','-c:v','h264_videotoolbox','-b:v','300k',str(f/'padded-848.mp4')])
# HLS AES-128 known test key (synthetic content, intentionally public fixture key).
d=f/'hls-aes128';d.mkdir(exist_ok=True);(d/'key.bin').write_bytes(bytes(range(16)))
import tempfile
keyinfo=Path(tempfile.gettempdir())/'ftplayer-aes-keyinfo.txt';keyinfo.write_text('key.bin\n'+str(d/'key.bin')+'\n000102030405060708090a0b0c0d0e0f\n')
run(base+['-c','copy','-f','hls','-hls_time','2','-hls_list_size','0','-hls_key_info_file',str(keyinfo),'-hls_segment_filename',str(d/'segment%d.ts'),str(d/'index.m3u8')])
# Dynamic resolution plus 4:4:4 -> NV12 conversion regression. Independent limited-range
# reference samples catch corrupt chroma even when a decoder still outputs sized frames.
with tempfile.TemporaryDirectory(prefix='ftplayer-resolution-') as temporary:
 temp=Path(temporary)
 for name,size in [('small','160x96'),('large','320x192')]:
  run(['-f','lavfi','-i','testsrc2=size='+size+':rate=10','-t','1','-c:v','mjpeg','-pix_fmt','yuvj444p','-f','mjpeg',str(temp/(name+'.mjpeg'))])
 (f/'resolution-change.mjpeg').write_bytes((temp/'small.mjpeg').read_bytes()+(temp/'large.mjpeg').read_bytes())
 run(['-i',str(temp/'large.mjpeg'),'-vf','scale=in_range=pc:out_range=tv:flags=bilinear','-sws_flags','bilinear','-pix_fmt','nv12','-f','rawvideo',str(temp/'large.nv12')])
 raw=(temp/'large.nv12').read_bytes(); framebytes=320*192*3//2
 points=[(x,y) for y in [16,64,128,176] for x in [16,64,128,192,256,304]]
 golden=[]
 for index in range(len(raw)//framebytes):
  frame=raw[index*framebytes:(index+1)*framebytes]
  golden.append([frame[320*192+(y//2)*320+x+channel] for x,y in points for channel in [0,1]])
 (f/'resolution-change-golden.json').write_text(json.dumps(golden))
# Independent pixel reference stays in codec display order, even when packet PTS
# in the source equals DTS. setpts changes only timestamps, never the picture order.
run(['-i',str(f/'photoprism-tsu-hevc.mp4'),'-vf','scale=64:36:flags=neighbor:in_range=tv:out_range=tv,format=yuv420p,setpts=N/(60*TB)','-fps_mode','passthrough','-f','rawvideo',str(f/'photoprism-tsu-reference.yuv')])
manifest=[]
for p in sorted(f.rglob('*')):
 if p.is_file():
  row={'path':str(p.relative_to(f)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'origin':('Synthetic testsrc2 MJPEG resolution change / independent limited-range NV12 reference; see prepare-fixtures.py' if p.name.startswith('resolution-change') else urls.get(p.name,'Derived locally from synthetic sample.mp4 or downloaded test clip; see prepare-fixtures.py'))}
  if p.suffix in ['.mp4','.webm','.mov','.mkv','.ts','.flv','.m4a','.h264','.h265'] and p.parent==f:
   check=subprocess.run([probe,'-v','error','-show_entries','stream=codec_name,codec_type,width,height,pix_fmt','-show_entries','format=duration,format_name','-of','json',str(p)],capture_output=True,text=True)
   row['probe']=json.loads(check.stdout) if check.returncode==0 else {'error':check.stderr}
  manifest.append(row)
report=r/'Validation/Network/fixtures-manifest.json'
report.parent.mkdir(parents=True,exist_ok=True)
report.write_text(json.dumps(manifest,indent=2))
print('Prepared',len(manifest),'fixture files;',sum(x['bytes'] for x in manifest),'bytes')
