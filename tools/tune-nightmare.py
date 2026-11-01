# Tunes the red-light sector (pre-conversion v62 main CR2W + nodeData buffer) before convert-sector-25.py.
# Changes, all on our own mod sector (no vanilla data touched):
#   1. every worldStaticLightNode without a scaleVolFog property gets scaleVolFog = 0 (all vanilla 2.5
#      apartment lamps have it 0; with the default the light also lights the fog = glowing blobs in the air)
#   2. drops the node setups of the green/teal lights (the nightmare should be red), keeps their node
#      definitions unused
#   3. scales the intensity of the very strong bathroom-door bounce lights down by BATH_SCALE
#   4. scales the two spots right above the bed (light_035 320, light_044 150; the vanilla lamp there,
#      light_012, is 200) down by BED_SCALE
# Usage: python tune-nightmare.py <main.bin> <buffer1.bin> <out_main.bin> <out_buffer1.bin>
import struct, sys, zlib

BATH_SCALE = 0.25
BED_SCALE = 0.25
BED_LIGHTS = ('light_035', 'light_044')

def header_crc(m):
    t = bytearray(m[:160]); struct.pack_into('<I', t, 32, 0xDEADBEEF)
    return zlib.crc32(bytes(t))

class C:
    def __init__(s, m):
        s.m = m
        s.tabs = [list(struct.unpack_from('<III', m, 40 + 12 * i)) for i in range(10)]
        so = s.tabs[0][0]; no, nn, _ = s.tabs[1]
        s.names = []
        for i in range(nn):
            off = struct.unpack_from('<I', m, no + 8 * i)[0]
            e = m.index(b'\0', so + off); s.names.append(m[so + off:e].decode())
        eo, ne, _ = s.tabs[4]
        s.exp = []
        for i in range(ne):
            cls, fl, par, size, off = struct.unpack_from('<HHIII', m, eo + 24 * i)
            s.exp.append(dict(cls=s.names[cls], size=size, off=off))
    def props(s, i):
        x = s.exp[i]; d = s.m; p = x['off']; end = p + x['size']; out = []
        assert d[p] == 0; p += 1
        while True:
            ni, ti = struct.unpack_from('<HH', d, p)
            if ni == 0: break
            sz = struct.unpack_from('<I', d, p + 4)[0]
            out.append([s.names[ni], s.names[ti], bytes(d[p + 8:p + 4 + sz])]); p += 4 + sz
        return out, bytes(d[p:end])     # trailing bytes after the 00 00 terminator (kept as is)
    def pack(s, props, tail):
        b = bytearray(b'\0')
        for n, t, v in props:
            b += struct.pack('<HHI', s.names.index(n), s.names.index(t), len(v) + 4) + v
        return bytes(b + tail)

def main():
    mainf, buff, outm, outb = sys.argv[1:5]
    m = bytearray(open(mainf, 'rb').read()); c = C(m)
    assert struct.unpack_from('<I', m, 32)[0] == header_crc(m)
    buf = open(buff, 'rb').read(); assert len(buf) % 144 == 0
    # canonical property order of lights, learned from the lights that have scaleVolFog
    order = []
    for i, x in enumerate(c.exp):
        if x['cls'] == 'worldStaticLightNode':
            for n, t, v in c.props(i)[0]:
                if n not in order: order.append(n)
    # node index -> export index: nodes are exports 1..N in handle order (checked: handles 2,3,... = export+1)
    newdata = {}
    def light(i):
        return {n: v for n, t, v in c.props(i)[0]}
    keep = []; dropped = []; scaled = []; fogged = []
    for r in range(len(buf) // 144):
        rec = buf[r * 144:(r + 1) * 144]
        ni = struct.unpack_from('<Q', rec, 120)[0] & 0xFFFFF
        ei = 1 + ni; x = c.exp[ei]
        if x['cls'] != 'worldStaticLightNode':
            keep.append(rec); continue
        props, tail = c.props(ei)
        pd = {n: v for n, t, v in props}
        dn = c.names[struct.unpack_from('<H', pd['debugName'], 0)[0]]
        col = pd['color']; rgb = (col[9], col[18], col[27])
        if rgb[1] > rgb[0]:
            dropped.append('%s rgb%s' % (dn, rgb)); continue
        keep.append(rec)
        if ei in newdata: continue
        changed = False
        if 'scaleVolFog' not in pd:
            pos = len(props)
            for k, (n, t, v) in enumerate(props):
                if order.index(n) > order.index('scaleVolFog'): pos = k; break
            props.insert(pos, ['scaleVolFog', 'Uint8', b'\0']); changed = True; fogged.append(dn)
        scale = None
        if 'bathroom_bounce_door' in dn and 'intensity' in pd and struct.unpack('<f', pd['intensity'])[0] >= 1000:
            scale = BATH_SCALE
        if dn in BED_LIGHTS:
            scale = BED_SCALE
        if scale is not None:
            assert 'intensity' in pd, dn
            for p in props:
                if p[0] == 'intensity':
                    old = struct.unpack('<f', p[2])[0]; p[2] = struct.pack('<f', old * scale)
                    scaled.append('%s %.0f -> %.0f' % (dn, old, old * scale))
            changed = True
        if changed: newdata[ei] = c.pack(props, tail)
    print('dropped setups (green/teal):', len(dropped), dropped)
    print('scaleVolFog=0 added:', fogged)
    print('intensity scaled:', scaled)
    # rebuild export data
    eo, ne, _ = c.tabs[4]
    first = c.exp[0]['off']; blob = bytearray(); offs = []
    assert all(c.exp[i]['off'] == (c.exp[i - 1]['off'] + c.exp[i - 1]['size']) for i in range(1, ne)), 'exports not contiguous'
    for i, x in enumerate(c.exp):
        dat = newdata.get(i, bytes(m[x['off']:x['off'] + x['size']]))
        offs.append((first + len(blob), len(dat))); blob += dat
    old_end = c.exp[-1]['off'] + c.exp[-1]['size']
    delta = len(blob) - (old_end - first)
    m[first:old_end] = blob
    for i, (o, sz) in enumerate(offs):
        struct.pack_into('<II', m, eo + 24 * i + 8, sz, o)
    c.tabs[4][2] = zlib.crc32(bytes(m[eo:eo + 24 * ne]))
    newbuf = b''.join(keep)
    bo, nb, _ = c.tabs[5]
    for i in range(nb):
        e = bo + 24 * i
        struct.pack_into('<I', m, e + 8, struct.unpack_from('<I', m, e + 8)[0] + delta)
    struct.pack_into('<I', m, bo + 16, len(newbuf))     # buffer 1 memSize (disk size/crc set by the converter)
    c.tabs[5][2] = zlib.crc32(bytes(m[bo:bo + 24 * nb]))
    for i in (4, 5): struct.pack_into('<III', m, 40 + 12 * i, *c.tabs[i])
    for f in (24, 28): struct.pack_into('<I', m, f, struct.unpack_from('<I', m, f)[0] + delta)
    struct.pack_into('<I', m, 32, header_crc(m))
    open(outm, 'wb').write(m); open(outb, 'wb').write(newbuf)
    print('main %d -> %d bytes, setups %d -> %d' % (old_end + 0, len(m), len(buf) // 144, len(newbuf) // 144))

main()
