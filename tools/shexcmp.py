"""Print the number of differing bytes between two DXBC files' code chunks; 0 means identical."""
import struct, sys

def shex(p):
    d = open(p, 'rb').read()
    (n,) = struct.unpack_from('<I', d, 28)
    for o in struct.unpack_from('<%dI' % n, d, 32):
        if d[o:o + 4] in (b'SHEX', b'SHDR'):
            (sz,) = struct.unpack_from('<I', d, o + 4)
            return d[o + 8:o + 8 + sz]
    return b''

a, b = shex(sys.argv[1]), shex(sys.argv[2])
print(0 if a == b else sum(1 for x, y in zip(a, b) if x != y) + abs(len(a) - len(b)))
