#!/usr/bin/env python3
"""Integration checks for explicit video modes (uses disposable local fixtures)."""
import hashlib,json,subprocess,sys,tempfile
from pathlib import Path
binary=str(Path(sys.argv[1] if len(sys.argv)>1 else '.build/debug/Petalwheel').resolve())
def run(*args):
 return subprocess.run(args,check=True,capture_output=True).stdout
def probe(p):
 return json.loads(run('ffprobe','-v','error','-show_streams','-show_format','-of','json',str(p)))
def audio_hash(p):
 return hashlib.sha256(run('ffmpeg','-v','error','-i',str(p),'-map','0:a:0','-c:a','copy','-f','s16le','-')).hexdigest()
with tempfile.TemporaryDirectory(prefix='petalwheel-modes-') as tmp:
 d=Path(tmp); source=d/'fixture.mov'
 run('ffmpeg','-v','error','-f','lavfi','-i','testsrc2=size=320x180:rate=24:duration=2','-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=2','-c:v','libx264','-qp','0','-pix_fmt','yuv420p','-c:a','pcm_s16le',str(source))
 original_hash=hashlib.sha256(source.read_bytes()).hexdigest()
 for mode in ('fast','quality'):
  p=subprocess.run([binary,'--tool','compress','--video-mode',mode,str(source)],capture_output=True,text=True,check=True)
  output=next(Path(line) for line in p.stdout.splitlines() if line.startswith('/'))
  streams=probe(output)['streams'];v=next(s for s in streams if s['codec_type']=='video')
  assert output.suffix=='.mkv', 'PCM audio must use a compatible container'
  assert (v['codec_name'],v['width'],v['height'])==('hevc',320,180)
  assert abs(float(probe(output)['format']['duration'])-2)<0.1
  assert audio_hash(source)==audio_hash(output), 'Audio packets changed'
  assert hashlib.sha256(source.read_bytes()).hexdigest()==original_hash
  assert output.stat().st_size<source.stat().st_size
  print(mode+': HEVC, dimensions, duration, copied PCM audio and original integrity PASS',flush=True)
 # Preview uses the same encoder, leaves the source untouched, and produces a playable short clip.
 for mode in ('fast','quality'):
  p=subprocess.run([binary,'--preview',mode,str(source)],capture_output=True,text=True,check=True)
  preview=Path(p.stdout.strip())
  pv=probe(preview)
  assert 0<float(pv['format']['duration'])<=2.2
  assert next(x for x in pv['streams'] if x['codec_type']=='video')['codec_name']=='hevc'
  assert hashlib.sha256(source.read_bytes()).hexdigest()==original_hash
  import shutil
  assert preview.parent.name.startswith('petalwheel-')
  shutil.rmtree(preview.parent)
  print(mode+': playable preview and source integrity PASS',flush=True)
 # A 10-bit input must fail rather than silently reduce bit depth.
 ten=d/'ten-bit.mov'
 run('ffmpeg','-v','error','-f','lavfi','-i','testsrc2=size=320x180:rate=1:duration=1','-c:v','libx265','-pix_fmt','yuv420p10le','-x265-params','log-level=error:pools=1',str(ten))
 p=subprocess.run([binary,'--tool','compress','--video-mode','fast',str(ten)],capture_output=True,text=True)
 assert p.returncode!=0 and '10-bit' in p.stderr
 assert not list(d.glob('ten-bit (fast).*'))
 print('10-bit refusal without output PASS')
