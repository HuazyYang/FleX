"""Compare recompiled DXBC against the shipped blob at the byte level.

Text comparison is defeated by printer differences (FLT_MAX renders differently
in 3Dmigoto and FXC 6.3) and by register naming. The SHEX/SHDR chunk is the
actual executable bytecode: if it matches, the source reproduces the shader
exactly, with no interpretation required.
"""
import os, struct, subprocess, sys

ROOT = r"D:\ps\repo\fluid-dev\FleX"
OUT  = sys.argv[1]
FXC  = sys.argv[2]

def chunks(data):
    if data[:4] != b'DXBC': return {}
    (n,) = struct.unpack_from('<I', data, 28)
    offs = struct.unpack_from('<%dI' % n, data, 32)
    out = {}
    for o in offs:
        fourcc = data[o:o+4]
        (sz,) = struct.unpack_from('<I', data, o+4)
        out[fourcc] = data[o+8:o+8+sz]
    return out

rows = []
for line in open(os.path.join(ROOT,'src','shaders','Shaders.cfg'), encoding='utf-8'):
    line = line.strip()
    if not line or line.startswith('#'): continue
    p = line.split(); src = p[0]; entry=None; defs=[]
    i = 1
    while i < len(p):
        if p[i] == '-E': entry = p[i+1]; i += 2
        elif p[i] == '-T': i += 2
        elif p[i].startswith('-D'):
            # Both the attached (-DFOO=1) and separated (-D FOO=1) forms appear.
            if p[i] == '-D': defs.append('-D' + p[i+1]); i += 2
            else: defs.append(p[i]); i += 1
        else: i += 1
    if entry: rows.append((src, entry, defs))

os.makedirs(OUT, exist_ok=True)
exact = []; codeonly = []; differ = []; failed = []
for src, entry, defs in rows:
    # Blob naming is not uniform: Flex kernels use g_Flex_, the BVH group uses
    # g_bvh_, and the radix sort uses g_ with a capitalised entry point.
    cand = ['g_Flex_%s.txt' % entry, 'g_bvh_%s.txt' % entry,
            'g_%s.txt' % (entry[0].upper() + entry[1:])]
    blob = ''
    for c in cand:
        q = os.path.join(ROOT,'src','dxbc',c)
        if os.path.exists(q): blob = q; break
    if not blob: blob = os.path.join(ROOT,'src','dxbc',cand[0])
    srcp = os.path.join(ROOT,'src','shaders', src.replace('/', os.sep))
    if not os.path.exists(blob) or not os.path.exists(srcp):
        failed.append((entry,'missing')); continue
    tmp = os.path.join(OUT, entry + '.bin')
    cmd = [FXC,'-nologo','-T','cs_5_0','-E',entry,
           '-I'+os.path.join(ROOT,'external','nvapi','include'),
           '-I'+os.path.join(ROOT,'external','ags_lib','hlsl')] + defs + ['-Fo',tmp,srcp]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True)
    if r.returncode != 0 or not os.path.exists(tmp):
        failed.append((entry,'fxc failed')); continue
    A = open(blob,'rb').read(); B = open(tmp,'rb').read()
    if A == B:
        exact.append(entry); continue
    ca, cb = chunks(A), chunks(B)
    ka = ca.get(b'SHEX') or ca.get(b'SHDR')
    kb = cb.get(b'SHEX') or cb.get(b'SHDR')
    if ka is not None and ka == kb:
        codeonly.append((entry, sorted(set(ca)|set(cb), key=lambda x:x)))
    else:
        differ.append((entry, len(ka or b''), len(kb or b'')))

print("shaders: %d" % len(rows))
print("  FULL-FILE byte-identical to the shipped blob : %d" % len(exact))
print("  CODE CHUNK byte-identical (container differs): %d" % len(codeonly))
print("  code chunk differs                          : %d" % len(differ))
print("  failed                                      : %d" % len(failed))
if exact:
    print("\n=== full-file identical ===")
    for e in exact: print("   ", e)
if codeonly:
    print("\n=== code identical, container differs ===")
    for e,_ in codeonly: print("   ", e)
if differ:
    print("\n=== CODE DIFFERS (shipped bytes vs ours) ===")
    for e,la,lb in differ: print("    %-44s shipped=%-7d ours=%-7d delta=%+d" % (e,la,lb,lb-la))
if failed:
    print("\n=== failed ===")
    for e,w in failed: print("    %-44s %s" % (e,w))
