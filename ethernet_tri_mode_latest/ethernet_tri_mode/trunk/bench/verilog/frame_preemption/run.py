"""Independent zlib/byte-vector regression. Python 3.10+, Icarus Verilog.

Run from any directory: python run.py --iverilog <path/to/iverilog.exe>
Only writes bench/verilog/frame_preemption/results (or --output).
No third-party Python packages. No original Windows PLI required.
"""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shutil
import subprocess
import zlib

HERE = Path(__file__).resolve().parent
TRUNK = HERE.parents[2]
RTL = TRUNK / 'rtl' / 'verilog'
FP = RTL / 'frame_preemption'
START = [0xE6, 0x4C, 0x7F, 0xB3]
CONT = [0x61, 0x52, 0x9E, 0xAD]

def manifest_sources(path: Path, stack=()) -> list[Path]:
    """Read lists with nested -f relative to its parent, sources to trunk."""
    path = path.resolve()
    if path in stack:
        raise ValueError(f'recursive file list: {path}')
    sources=[]
    for raw in path.read_text(encoding='utf-8').splitlines():
        line=raw.strip()
        if not line or line.startswith(('#','//')):
            continue
        if line.startswith('-f '):
            sources.extend(manifest_sources(path.parent/line[3:].strip(), (*stack,path)))
        elif line.startswith('+incdir+'):
            directory=(TRUNK/line[len('+incdir+'):]).resolve()
            if not directory.is_relative_to(TRUNK) or not directory.is_dir():
                raise ValueError(f'invalid include directory: {line}')
        else:
            source=(TRUNK/line).resolve()
            if not source.is_relative_to(TRUNK) or not source.is_file():
                raise ValueError(f'invalid source: {line}')
            sources.append(source)
    if len(set(sources)) != len(sources):
        raise ValueError(f'duplicate sources in {path}')
    return sources

def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def frame(length: int, identity: int) -> bytes:
    r = random.Random(identity)
    body = bytes([0x02,0x12,0x34,0x56,identity & 255,0x78,
                  0x02,0x88,0x99,0xAA,0xBB,0xCC,0x08,0x00])
    body += bytes(r.randrange(256) for _ in range(length-4-len(body)))
    return body + zlib.crc32(body).to_bytes(4,'little')

def packet(data: bytes, smd=0xD5, fc=None) -> bytes:
    return bytes([0x55]*(7 if fc is None else 6) + [smd] + ([] if fc is None else [START[fc % 4]])) + data

def fragments(f: bytes, sizes: list[int], number: int) -> list[bytes]:
    packets=[]; offset=0
    for i,size in enumerate(sizes):
        end=offset+size
        data=f[offset:end]
        if end<len(f):
            data += (zlib.crc32(f[:end]) ^ 0xFFFF0000).to_bytes(4,'little')
        packets.append(packet(data, START[number] if i==0 else CONT[number], None if i==0 else i-1))
        offset=end
    assert offset==len(f)
    return packets

def check_tx(path: Path, expected: list[bytes], coverage=True, before=()) -> dict:
    rows=[tuple(int(x,16 if i==2 else 10) for i,x in enumerate(line.split()))
          for line in path.read_text().splitlines()]
    packets=[]; current=[]; first=0; previous_end=None; gaps=[]
    for cycle,en,data in rows:
        if en:
            if not current:
                first=cycle
                if previous_end is not None:
                    gaps.append(cycle-previous_end-1)
                    assert gaps[-1]>=12, 'IFG shorter than 12 bytes'
            current.append(data)
        elif current:
            packets.append((bytes(current),first,cycle-1)); previous_end=cycle-1; current=[]
    assert not current, 'unterminated wire packet'
    seen=[]; p=bytearray(); frame_no=None; next_fc=0; nf=0; all_nos=[]
    first_cont=None; frag_lengths=[]
    for raw,begin,end in packets:
        pre=0
        while raw[pre]==0x55: pre+=1
        smd=raw[pre]
        if smd==0xD5:
            assert pre==7
            data=raw[8:]
            assert zlib.crc32(data[:-4])==int.from_bytes(data[-4:],'little')
            seen.append(data)
        else:
            if smd in START:
                assert pre==7 and not p
                frame_no=START.index(smd); next_fc=0; data=raw[8:]
                all_nos.append(frame_no)
            else:
                assert smd in CONT and pre==6 and CONT.index(smd)==frame_no
                assert raw[7]==START[next_fc % 4], 'wrong continuation fragment count'
                next_fc+=1; data=raw[8:]
                if first_cont is None: first_cont=raw[7]
            assert len(data)>=64
            candidate=bytes(p)+data[:-4]
            crc=int.from_bytes(data[-4:],'little')
            if crc==(zlib.crc32(candidate)^0xFFFF0000):
                p.extend(data[:-4]); nf+=1; frag_lengths.append(len(data)-4)
            else:
                assert crc==zlib.crc32(candidate), 'bad cumulative CRC or original final FCS'
                seen.append(candidate+data[-4:]); p.clear(); frame_no=None
    assert not p
    assert sorted(seen)==sorted(expected), 'lost, duplicated or altered frames'
    assert len(packets)==len(expected)+nf
    # Check the preemption outcome as well as unordered payload equality.
    for earlier,later in before:
        assert seen.index(earlier)<seen.index(later), 'express did not overtake suspended p frame'
    if coverage:
        assert set(all_nos)=={0,1,2,3}, 'frame number wrap not exercised'
        assert nf>=11 and first_cont==START[0]
        for minimum in (60,124,188,252): assert minimum in frag_lengths, (minimum,frag_lengths)
    return {'frames':len(seen),'wire_packets':len(packets),'non_final_fragments':nf,
            'frame_numbers':all_nos,'non_final_data_lengths':frag_lengths,'minimum_ifg':min(gaps) if gaps else None,
            'overtake_checks':len(before)}

def check_rx(path: Path, expected: list[tuple[int,bytes]]) -> dict:
    actual=[]; data=bytearray(); kind=None
    for line in path.read_text().splitlines():
        c,sop,last,b=line.split(); c=int(c); sop=int(sop); last=int(last); b=int(b,16)
        if sop: assert not data; kind=c
        else: assert data and kind==c
        data.append(b)
        if last: actual.append((kind,bytes(data))); data.clear()
    assert not data
    assert sorted(actual)==sorted(expected), f'RX committed frames differ: actual={len(actual)}, expected={len(expected)}'
    return {'committed_frames':len(actual),'express':sum(c==0 for c,_ in actual),
            'preemptable':sum(c==1 for c,_ in actual)}

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--iverilog'); ap.add_argument('--output',type=Path)
    args=ap.parse_args(); out=(args.output or HERE/'results').resolve(); out.mkdir(parents=True,exist_ok=True)
    iv=Path(args.iverilog or shutil.which('iverilog') or 'iverilog')
    if not iv.is_absolute():
        resolved=shutil.which(str(iv))
        if resolved: iv=Path(resolved)
        elif iv.is_file(): iv=iv.resolve()
    vv=iv.with_name('vvp'+iv.suffix)
    env=os.environ.copy(); env['TMP']=str(out); env['TMPDIR']=str(out)
    (out/'commands.log').write_text('',encoding='utf-8')
    def run(cmd):
        p=subprocess.run([str(x) for x in cmd],cwd=out,env=env,text=True,capture_output=True,timeout=90)
        with (out/'commands.log').open('a',encoding='utf-8') as log:
            log.write(' '.join(str(x) for x in cmd)+'\n'+p.stdout+p.stderr+'\n')
        if p.returncode: raise RuntimeError(p.stdout+p.stderr)
        return p.stdout.strip()
    iv_version=run([iv,'-V'])
    run([vv,'-V'])
    # Old MinGW Icarus cannot decode CJK source paths. Stage sources to ASCII basenames.
    # The caller should use an ASCII output path on Windows with this old toolchain.
    src=out/'src'; src.mkdir(exist_ok=True)
    source_paths=manifest_sources(FP/'fp_sim.f')
    headers=[RTL/'miim'/'timescale.v',FP/'fp_crc.vh']
    testbenches=[HERE/f'{name}.sv' for name in ('tb_fp_merge','tb_fp_edges','tb_fp_rx','tb_fp_top')]
    tracked=source_paths+headers+testbenches+[Path(__file__).resolve(),FP/'fp_core.f',FP/'fp_sim.f']
    hashes={p.relative_to(TRUNK).as_posix():sha256(p) for p in tracked}
    staged=source_paths+headers+testbenches
    if len({p.name for p in staged}) != len(staged):
        raise ValueError('staging basename collision')
    for p in staged:
        shutil.copy2(p,src/p.name)
        assert sha256(src/p.name)==hashes[p.relative_to(TRUNK).as_posix()]
    all_sources=[src/p.name for p in source_paths]
    def sim(tb,plus):
        executable=out/(tb+'.vvp')
        print(run([iv,'-g2012','-Wall','-I',src,'-s',tb,'-o',executable,
                   *all_sources,src/(tb+'.sv')]))
        print(run([vv,executable,*plus]))
    tx_lengths=[64,123,64,1800]+[64]*8+[600]*3+[64]*3+[2050,63]+[64]*8
    txframes=[frame(n,i+1) for i,n in enumerate(tx_lengths)]
    (out/'tx.mem').write_text('\n'.join(f'{b:02x}' for f in txframes for b in f)+'\n')
    sim('tb_fp_merge',[f'+VECTORS={out/"tx.mem"}',f'+TRACE={out/"tx.trace"}',
                       f'+COUNT={sum(tx_lengths)}'])
    expected=txframes[:18]+txframes[20:]
    before=[(txframes[2],txframes[1])]+[(txframes[i],txframes[3]) for i in range(4,12)]
    before += [(txframes[15+i],txframes[12+i]) for i in range(3)]
    report={'tx':check_tx(out/'tx.trace',expected,before=before)}
    edge_lengths=[n for minimum in (60,124,188,252) for n in (minimum+63,minimum+64)]
    edge_lengths += [2048,2049,64]
    edge_frames=[frame(n,500+i) for i,n in enumerate(edge_lengths)]
    (out/'edge.mem').write_text('\n'.join(f'{b:02x}' for f in edge_frames for b in f)+'\n')
    sim('tb_fp_edges',[f'+VECTORS={out/"edge.mem"}',f'+TRACE={out/"edge.trace"}',
                       f'+COUNT={sum(edge_lengths)}'])
    report['edges']=check_tx(out/'edge.trace',edge_frames[:9]+edge_frames[10:],coverage=False)
    assert report['edges']['non_final_data_lengths']==[60,124,188,252]
    report['edges']['boundary_lengths']=edge_lengths[:8]
    report['edges']['link_loss_partial_input']='passed'
    report['edges']['reset_in_tx_data']='passed'

    rng=random.Random(0x8023); feed=[]; rx_expected=[]
    def idle(n,ready=None):
        feed.extend((int(rng.randrange(4)!=0) if ready is None else int(ready))<<11 for _ in range(n))
    def emit(raw, error_at=None, ready=None):
        for i,b in enumerate(raw):
            r=int(rng.randrange(4)!=0) if ready is None else int(ready)
            feed.append((r<<11)|(int(i==error_at)<<9)|0x100|b)
        idle(12,ready)
    # Reset invalidates a suspended assembly; an independent fresh frame recovers.
    p=frame(200,90); parts=fragments(p,[60,140],0)
    emit(parts[0]); feed.extend([0x1800]*4); idle(10)
    emit(parts[1]); idle(100)
    e=frame(2048,91); emit(packet(e)); rx_expected.append((0,e)); idle(2500)
    for number in range(4):
        f=frame(900,100+number)
        pieces=fragments(f,[60]*8+[420],number)
        for i,piece in enumerate(pieces):
            emit(piece)
            if i<8:
                e=frame(64,200+number*8+i); emit(packet(e)); rx_expected.append((0,e))
        rx_expected.append((1,f)); idle(2500)
    # Unfragmented p, then a packet with a bad FCS and one with RX_ER.
    p=frame(64,301); emit(packet(p,START[0])); rx_expected.append((1,p)); idle(300)
    e=frame(64,302); bad=bytearray(packet(e)); bad[-1]^=1; emit(bad); idle(100)
    emit(packet(e),error_at=30); idle(100)
    # Missing, duplicated, out-of-order fragments and wrong frame number.
    p=frame(300,303); pieces=fragments(p,[60,60,180],1)
    emit(pieces[0]); emit(pieces[2]); idle(100)
    emit(pieces[0]); emit(pieces[1]); emit(pieces[1]); emit(pieces[2]); idle(100)
    emit(pieces[0]); bad=bytearray(pieces[1]); bad[6]=CONT[2]; emit(bad); emit(pieces[2]); idle(100)
    # Corrupt cumulative mCRC, illegal SMD, truncated packet, and oversized frame.
    bad=bytearray(pieces[0]); bad[-2]^=2; emit(bad); emit(pieces[1]); idle(100)
    emit(bytes([0x55]*7+[0xE7])+frame(64,304)); emit(packet(e)[:20]); idle(100)
    emit(packet(frame(2050,305))); idle(100)
    # Overrun is counted, buffer contents are protected until output is consumed.
    a=frame(64,306); b=frame(64,307); c=frame(64,309)
    emit(packet(a),ready=False); emit(packet(b),ready=False); emit(packet(c),ready=False); idle(50,False)
    rx_expected.extend([(0,a),(0,b)]); idle(500,True)
    # New valid start abandons incomplete p context and recovers.
    emit(pieces[0]); p=frame(128,308); emit(packet(p,START[3])); rx_expected.append((1,p)); idle(1000)
    # Sustained minimum frames at 12-byte IFG exercise ping-pong turnover.
    for i in range(32):
        e=frame(64,600+i); emit(packet(e),ready=True); rx_expected.append((0,e))
    idle(500,True)
    (out/'rx.mem').write_text('\n'.join(f'{v:03x}' for v in feed)+'\n')
    sim('tb_fp_rx',[f'+VECTORS={out/"rx.mem"}',f'+TRACE={out/"rx.trace"}',f'+COUNT={len(feed)}'])
    report['rx']=check_rx(out/'rx.trace',rx_expected)
    report['rx']['stimulus_cycles']=len(feed)
    # Elaborate both actual tops from exactly the delivered simulation manifest.
    for top in ['MAC_top','MAC_top_fp']:
        print(run([iv,'-g2012','-I',src,'-s',top,'-o',out/(top+'.vvp'),*all_sources]))
    report['elaboration']=['MAC_top','MAC_top_fp']
    top_frames=[frame(n+4,400+i) for i,n in enumerate([996,61,62,63,60])]
    (out/'top.mem').write_text('\n'.join(f'{b:02x}' for f in top_frames for b in f[:-4])+'\n')
    print(run([iv,'-g2012','-I',src,'-s','tb_fp_top','-o',out/'tb_fp_top.vvp',
               *all_sources,src/'tb_fp_top.sv']))
    stdout=run([vv,out/'tb_fp_top.vvp',f'+VECTORS={out/"top.mem"}',
                f'+TRACE={out/"top.trace"}',f'+WIRE={out/"top_wire.trace"}',
                f'+COUNT={sum(len(f)-4 for f in top_frames)}'])
    print(stdout)
    report['top_wire']=check_tx(out/'top_wire.trace',top_frames,coverage=False,
                                before=[(top_frames[1],top_frames[0])])
    received=[]; data=bytearray()
    for line in (out/'top.trace').read_text().splitlines():
        sop,eop,be,word=line.split(); sop=int(sop); eop=int(eop); be=int(be)
        if sop: assert not data, 'unexpected SOP'
        else: assert data, 'missing SOP'
        data.extend(bytes.fromhex(word)[:be if eop and be else 4])
        if eop: received.append(bytes(data)); data.clear()
    assert not data and sorted(received)==sorted(f[:-4] for f in top_frames), 'top RX payload/BE mismatch'
    assert received.index(top_frames[1][:-4]) < received.index(top_frames[0][:-4]), 'top RX did not deliver express before suspended p frame'
    lengths=[int(line.split()[1]) for line in stdout.splitlines() if line.startswith('LENGTH ')]
    assert sorted(lengths)==sorted(len(f)-4 for f in top_frames), f'length FIFO mismatch {lengths}'
    report['top']={'received_frames':len(received),'payload_lengths':lengths,
                   'first_word_priority_lock':'passed with priority changed on every later word',
                   'express_overtake_wire_and_user':'passed',
                   'clocks_ns':{'tx':8,'user':10,'reg':14,'rx':8},'rx_phase_offset_ns':2,
                   'ram_model':'verification-only synchronous one-cycle read RAM'}
    (out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    assert all(sha256(p)==hashes[p.relative_to(TRUNK).as_posix()] for p in tracked), 'sources changed during regression'
    evidence={'completed_utc':datetime.now(timezone.utc).isoformat(),
              'python':platform.python_version(),'iverilog':iv_version,
              'vvp_version_in':'commands.log (vvp -V writes its version to stderr)',
              'simulation_manifest':'rtl/verilog/frame_preemption/fp_sim.f',
              'source_root':'ethernet_tri_mode_latest/ethernet_tri_mode/trunk',
              'sha256':hashes,'rx_ready_seed':'0x8023',
              'frame_data_seed':'each frame identity; see run.py',
              'scope':'forced-mode prototype; local RTL simulation and elaboration only'}
    (out/'source_manifest.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False,indent=2))

if __name__=='__main__': main()
