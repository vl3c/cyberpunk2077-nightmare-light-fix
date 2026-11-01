# Converts a version-62 (patch 2.31) cooked .streamingsector (main CR2W + its nodeData buffer) to the 2.5 layout
# of worldCompiledNodeInstanceSetupInfo, and rebuilds an RDAR archive with the converted file.
#
# Pre-2.5 record (144 bytes), per WolvenKit before commit 9507415:
#   0..111 transform/scale/ref points/hashes (unchanged in 2.5)
#   112 f32 secondaryRefPointDistance, 116 f32 streamingDistance,
#   120 u64 bitfield: nodeIdx bits 0..19, nodeFlags bits 20..40, streamingPriority bits 41..48, todvis 49..63
#   128..143 zero
# 2.5 record (WolvenKit worldNodeDataReader, "2.5 and later"):
#   112 u64 bitfield: nodeIdx bits 0..18, nodeFlags bits 19..39, streamingPriority 40..47, todvisMask 48..63
#   120 f32 secondaryRefPointDistance, 124 f32 streamingDistance, 128 u32 instanceIndex,
#   132 u8 dataGroup, 133..143 zero padding
# The old bit positions were derived by matching every node class in the mod sector against
# the vanilla 2.5 sector exterior_-22_19_1_0 (lights 0x40/1, probes 0x42/1, triggers 0x42/255,
# meshes 0x82040/40 in both after conversion).
#
# Usage: python convert-sector-25.py <src.archive> <out.archive> <sectorHashHex> <main.bin> <buffer1.bin> [<keepHash> ...]
import struct, sys, zlib

def check(cond, msg):
    # real checks, not asserts: they must also run under python -O
    if not cond:
        raise SystemExit('ERROR: ' + msg)

def read_vlq(b, p):
    # CR2W packed int: first byte bit7 = flag, bit6 = continue, low 6 bits value; then 7 bits per byte
    x = b[p]; v = x & 0x3F; p += 1; sh = 6
    if x & 0x40:
        while True:
            x = b[p]; p += 1; v |= (x & 0x7F) << sh; sh += 7
            if not x & 0x80: break
    return v, p

def read_str_len(b, p):
    # node ref strings: packed length with bit7 of the first byte set for 1-byte (ASCII/UTF-8) text;
    # without it the text would be UTF-16, which these sectors never use
    check(b[p] & 0x80, 'UTF-16 node ref string at offset %d is not supported' % p)
    return read_vlq(b, p)

def noderef_hash(s):
    # NodeRef hash = FNV-1a 64 of the path with every '#' skipped (matches vanilla setup globalNodeID)
    h = 0xcbf29ce484222325
    for ch in s:
        if ch == 0x23: continue
        h ^= ch; h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h

def single_node_range(m, exp_off, exp_cnt, root_off, root_size, vpos):
    # The streaming block describes this sector with numNodeRanges = 1 and no variants. In the 2.5 world
    # block every descriptor without variants has numNodeRanges 1, and the vanilla 2.5 sector
    # exterior_-22_19_1_0 has exactly numNodeRanges (115) variantIndices entries. The mod sector had
    # variantIndices [0, 1]: range 0 = one dummy probe at the origin, range 1 = all real nodes, a range the
    # block never declares. Make it one range [0] that covers every node. Removes 4 bytes from the root.
    p = root_off + vpos + 12
    n, p = read_vlq(m, p); p += 4 * n
    n, p = read_vlq(m, p)
    for _ in range(n):
        l, q = read_str_len(m, p); p = q + l
    cpos = p
    nv, p = read_vlq(m, p)
    vi = list(struct.unpack_from('<%dI' % nv, m, p))
    print('variantIndices before:', vi)
    if vi == [0]:
        return m, 0
    check(nv == 2 and vi[0] == 0 and m[cpos] == 2, 'unexpected variantIndices layout')
    m[cpos:p + 4 * nv] = bytes([1]) + struct.pack('<I', 0)
    d = -4
    struct.pack_into('<i', m, root_off + vpos + 4, struct.unpack_from('<i', m, root_off + vpos + 4)[0] + d)
    for i in range(exp_cnt):
        e = exp_off + 24 * i
        size, off = struct.unpack_from('<II', m, e + 8)
        if i == 0:
            check(off == root_off and size == root_size, 'first export is not the sector root')
            struct.pack_into('<I', m, e + 8, size + d)
        elif off > root_off:
            struct.pack_into('<I', m, e + 12, off + d)
    tabs = [list(struct.unpack_from('<III', m, 40 + 12 * i)) for i in range(10)]
    tabs[4][2] = zlib.crc32(bytes(m[exp_off:exp_off + 24 * exp_cnt]))
    boff, bcnt, _ = tabs[5]
    for i in range(bcnt):
        struct.pack_into('<I', m, boff + 24 * i + 8, struct.unpack_from('<I', m, boff + 24 * i + 8)[0] + d)
    tabs[5][2] = zlib.crc32(bytes(m[boff:boff + 24 * bcnt]))
    for i in (4, 5): struct.pack_into('<III', m, 40 + 12 * i, *tabs[i])
    for f in (24, 28): struct.pack_into('<I', m, f, struct.unpack_from('<I', m, f)[0] + d)
    struct.pack_into('<I', m, 32, header_crc(m))
    print('variantIndices after: [0] (root %d -> %d bytes)' % (root_size, root_size + d))
    return m, d

def sort_noderefs(m, root_off, vpos):
    # 2.5 sectors store nodeRefs sorted by hash (checked on the vanilla 2.5 sector exterior_-22_19_1_0:
    # all 163 entries ascending). The mod sector's 57 refs were in authoring order.
    p = root_off + vpos + 12           # version, inner size, nodeData DataBuffer
    n, p = read_vlq(m, p); p += 4 * n  # node handles
    n, p = read_vlq(m, p)
    start = p; recs = []
    for _ in range(n):
        l, q = read_str_len(m, p)
        s = bytes(m[q:q + l]); recs.append((noderef_hash(s.split(b';')[0]), bytes(m[p:q + l]))); p = q + l
    srt = sorted(recs, key=lambda r: r[0])
    m[start:p] = b''.join(r[1] for r in srt)
    print('nodeRefs: %d entries, %s -> sorted by hash' % (n, 'already sorted' if srt == recs else 'reordered'))

def crc64_xz(data):
    poly = 0xC96C5795D7870F42
    tbl = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (c >> 1) ^ poly if c & 1 else c >> 1
        tbl.append(c)
    crc = 0xFFFFFFFFFFFFFFFF
    for b in data:
        crc = tbl[(crc ^ b) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFFFFFFFFFF

def header_crc(m):
    # WolvenKit CR2WWriter.CalculateHeaderCRC32: header fields with 0xDEADBEEF in place of crc, then the 10 table headers
    t = bytearray(m[:160]); struct.pack_into('<I', t, 32, 0xDEADBEEF)
    return zlib.crc32(bytes(t))

def convert_records(buf, node_count):
    check(len(buf) % 144 == 0, 'nodeData buffer size is not a multiple of 144')
    out = bytearray()
    for r in range(len(buf) // 144):
        rec = bytearray(buf[r * 144:(r + 1) * 144])
        sd, st = struct.unpack_from('<2f', rec, 112)
        old = struct.unpack_from('<Q', rec, 120)[0]
        check(not any(rec[128:144]), 'record %d: bytes 128..143 not zero, not a pre-2.5 record' % r)
        ni = old & 0xFFFFF
        flags = (old >> 20) & 0x1FFFFF
        prio = (old >> 41) & 0xFF
        todvis = (old >> 49) & 0x7FFF
        check(ni < node_count and ni <= 0x7FFFF, 'record %d: node index %d out of range' % (r, ni))
        new = ni | (flags << 19) | (prio << 40) | (todvis << 48)
        struct.pack_into('<Q', rec, 112, new)
        struct.pack_into('<2f', rec, 120, sd, st)
        struct.pack_into('<i', rec, 128, -1)     # instanceIndex: none (no instanced/cooked nodes in this sector)
        rec[132] = 0                             # dataGroup
        rec[133:144] = b'\0' * 11
        print('  setup %2d: node %2d flags 0x%x prio %d todvis %d dist %.2f/%.2f' % (r, ni, flags, prio, todvis, sd, st))
        out += rec
    return bytes(out)

def main():
    src, outp, shash = sys.argv[1], sys.argv[2], int(sys.argv[3], 16)
    mainf, buf1f = sys.argv[4], sys.argv[5]
    keep = [int(h, 16) for h in sys.argv[6:]]
    m = bytearray(open(mainf, 'rb').read())
    check(m[:4] == b'CR2W', 'not a CR2W file: ' + mainf)
    check(struct.unpack_from('<I', m, 32)[0] == header_crc(m), 'header CRC rule does not match source')
    tabs = [list(struct.unpack_from('<III', m, 40 + 12 * i)) for i in range(10)]
    exp_off, exp_cnt, _ = tabs[4]
    boff, bcnt, bcrc = tabs[5]
    check(zlib.crc32(bytes(m[boff:boff + 24 * bcnt])) == bcrc, 'buffer table CRC mismatch')
    bufs = [list(struct.unpack_from('<IIIIII', m, boff + 24 * i)) for i in range(bcnt)]
    print('buffers before:', bufs)
    old1 = open(buf1f, 'rb').read()
    check(bufs[0][4] == len(old1), 'buffer1 size does not match the main file')
    # count world*Node exports for the node index range check
    names_off, names_cnt, _ = tabs[1]
    strs_off = tabs[0][0]
    def name(i):
        o = struct.unpack_from('<I', m, names_off + 8 * i)[0]
        e = m.index(b'\0', strs_off + o); return m[strs_off + o:e].decode()
    node_count = 0
    for i in range(exp_cnt):
        cls = struct.unpack_from('<H', m, exp_off + 24 * i)[0]
        n = name(cls)
        if n.startswith('world') and n.endswith('Node'): node_count += 1
    print('node exports:', node_count)
    # worldStreamingSector custom data starts right after the RTTI properties: int32 version
    # (62 = patch 2.31 layout, 68 = patch 2.5 layout), int32 inner size, then nodeData etc.
    # The game picks the setup layout from this version, so it must match the converted bytes.
    root_size, root_off = struct.unpack_from('<II', m, exp_off + 8)
    root = m[root_off:root_off + root_size]
    vpos = root.find(b'\x00\x00' + struct.pack('<i', 62))
    check(vpos > 0, 'version 62 not found after the sector properties')
    vpos += 2
    check(struct.unpack_from('<i', root, vpos + 4)[0] == root_size - vpos - 4, 'inner size check failed')  # counts from the size field itself
    struct.pack_into('<i', m, root_off + vpos, 68)
    print('sector version 62 -> 68 at root offset', vpos)
    sort_noderefs(m, root_off, vpos)
    m, d = single_node_range(m, exp_off, exp_cnt, root_off, root_size, vpos)
    tabs = [list(struct.unpack_from('<III', m, 40 + 12 * i)) for i in range(10)]
    boff, bcnt, bcrc = tabs[5]
    bufs = [list(struct.unpack_from('<IIIIII', m, boff + 24 * i)) for i in range(bcnt)]
    new1 = convert_records(old1, node_count)
    # store converted buffer uncompressed: diskSize == memSize, crc over on-disk bytes
    delta = len(new1) - bufs[0][3]
    bufs[0][3] = len(new1); bufs[0][4] = len(new1); bufs[0][5] = zlib.crc32(new1)
    for b in bufs[1:]: b[2] += delta
    for i, b in enumerate(bufs): struct.pack_into('<IIIIII', m, boff + 24 * i, *b)
    tabs[5][2] = zlib.crc32(bytes(m[boff:boff + 24 * bcnt]))
    struct.pack_into('<III', m, 40 + 12 * 5, *tabs[5])
    bufend = struct.unpack_from('<I', m, 28)[0]
    struct.pack_into('<I', m, 28, bufend + delta)
    struct.pack_into('<I', m, 32, header_crc(m))
    print('buffers after:', bufs)

    d = open(src, 'rb').read()
    magic, ver, ipos, isz = struct.unpack_from('<4sIQI', d, 0)
    check(magic == b'RDAR' and ver == 12, 'not an RDAR v12 archive: ' + src)
    idx = d[ipos:ipos + isz]
    _, _, crc, nf, ns, nd = struct.unpack_from('<IIQIII', idx, 0)
    check(crc == crc64_xz(idx[16:]), 'archive index CRC mismatch: ' + src)
    p = 28; entries = []
    for i in range(nf):
        entries.append(list(struct.unpack_from('<QQIIIII', idx, p)) + [idx[p + 36:p + 56]]); p += 56
    segs = [struct.unpack_from('<QII', idx, p + 16 * i) for i in range(ns)]; p += 16 * ns
    deps = [struct.unpack_from('<Q', idx, p + 8 * i)[0] for i in range(nd)]
    byhash = {e[0]: e for e in entries}
    want = sorted(set(keep + [shash]))
    data = bytearray(b'\0' * 0xAC)
    newe, news, newd = [], [], []
    for h in want:
        check(h in byhash, 'file %016x not found in %s (not the Deceptious Bug Fixes archive?)' % (h, src))
        hsh, ts, ninl, ss, se, ds, de, sha = byhash[h]
        s0 = len(news)
        for k, s in enumerate(range(ss, se)):
            off, zs, sz = segs[s]
            if h == shash and k == 0:
                blob = bytes(m)            # converted main CR2W, stored raw
                news.append((len(data), len(blob), len(blob))); data += blob
            elif h == shash and k == 1:
                news.append((len(data), len(new1), len(new1))); data += new1
            else:
                news.append((len(data), zs, sz)); data += d[off:off + zs]
        d0 = len(newd); newd += deps[ds:de]
        newe.append((hsh, ts, ninl, s0, len(news), d0, len(newd), sha))
    while len(data) % 4096: data += b'\0'
    table = struct.pack('<III', len(newe), len(news), len(newd))
    for e in newe: table += struct.pack('<QQIIIII', *e[:7]) + e[7]
    for s in news: table += struct.pack('<QII', *s)
    for x in newd: table += struct.pack('<Q', x)
    index = struct.pack('<IIQ', 8, len(table) + 8, crc64_xz(table)) + table
    newipos = len(data); data += index
    while len(data) % 4096: data += b'\0'
    struct.pack_into('<4sIQIQIQ', data, 0, b'RDAR', 12, newipos, len(index), 0, 0, len(data))
    open(outp, 'wb').write(data)
    print('wrote %s: %d files, %d segments, %d bytes' % (outp, len(newe), len(news), len(data)))

main()
