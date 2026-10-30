#!/usr/bin/env python3
"""Verify dynamic leveling within one recording, not just whole-file gain."""
import array,hashlib,json,math,subprocess,sys,tempfile,wave
from pathlib import Path
binary=str(Path(sys.argv[1] if len(sys.argv)>1 else '.build/debug/Petalwheel').resolve())
root=Path(sys.argv[2]) if len(sys.argv)>2 else Path(tempfile.mkdtemp(prefix='nurto-audio-test-'))
root.mkdir(parents=True,exist_ok=True)
source=root/'uneven.wav';rate=48000;seconds=8
samples=array.array('h')
for amp in (0.02,0.55,0.08):
 samples.extend(int(32767*amp*math.sin(2*math.pi*440*i/rate)) for i in range(rate*seconds))
with wave.open(str(source),'wb') as f:
 f.setnchannels(1);f.setsampwidth(2);f.setframerate(rate);f.writeframes(samples.tobytes())
digest=hashlib.sha256(source.read_bytes()).digest()
p=subprocess.run([binary,'--tool','levelAudio',str(source)],capture_output=True,text=True,check=True)
output=next(Path(x) for x in p.stdout.splitlines() if x.startswith('/'))
def measure(path):
 with wave.open(str(path),'rb') as f:
  assert f.getframerate()==rate
  values=array.array('h',f.readframes(f.getnframes()))
 levels=[]
 for k in range(3):
  part=values[int((k*seconds+3)*rate):int((k*seconds+5)*rate)]
  rms=math.sqrt(sum((v/32768)**2 for v in part)/len(part))
  levels.append(round(20*math.log10(max(rms,1e-10)),2))
 return levels,max(abs(x)/32768 for x in values),len(values)
before,_,n=measure(source);after,peak,m=measure(output)
report={'before_dbfs':before,'after_dbfs':after,'before_spread_db':round(max(before)-min(before),2),'after_spread_db':round(max(after)-min(after),2),'peak_dbfs':round(20*math.log10(peak),2),'duration_seconds':m/rate,'source_unchanged':digest==hashlib.sha256(source.read_bytes()).digest()}
(root/'leveling-result.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report),flush=True)
assert report['source_unchanged'] and abs(n-m)<=rate//10
assert report['after_spread_db']<6 and report['after_spread_db']<report['before_spread_db']/2
assert peak<1
print('PASS: uneven passages leveled, no clipping, duration and original preserved')
