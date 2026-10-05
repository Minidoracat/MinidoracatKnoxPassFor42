"""Extract vanilla 2x sprites (PZPK v1 Tiles2x.pack) into full 128xN cells for camera calibration.
用法：python extract_vanilla_sprites.py <out_dir> name1 name2 ...
Reader follows MinidoracatEconomyFor42/scripts/build_tiles.py check() (TexturePackPage.java:103-151).
"""
import io
import struct
import sys
from pathlib import Path

from PIL import Image

PACK = Path("D:/SteamLibrary/steamapps/common/ProjectZomboid/media/texturepacks/Tiles2x.pack")
out = Path(sys.argv[1])
want = set(sys.argv[2:])
out.mkdir(parents=True, exist_ok=True)
data = PACK.read_bytes()
assert data[:4] == b"PZPK"
pos = 4


def rint():
    global pos
    v = struct.unpack_from("<i", data, pos)[0]
    pos += 4
    return v


def rstr():
    global pos
    n = rint()
    s = data[pos:pos + n].decode("latin-1")
    pos += n
    return s


version, pages = rint(), rint()
found = 0
for _ in range(pages):
    name, n, mask = rstr(), rint(), rint()
    entries = [(rstr(), [rint() for _ in range(8)]) for _ in range(n)]
    plen = rint()
    hits = [(en, v) for en, v in entries if en in want]
    if hits:
        page = Image.open(io.BytesIO(data[pos:pos + plen])).convert("RGBA")
        for en, (x, y, w, h, ox, oy, fx, fy) in hits:
            cell = Image.new("RGBA", (fx, fy), (0, 0, 0, 0))
            cell.paste(page.crop((x, y, x + w, y + h)), (ox, oy))
            cell.save(out / f"{en}.png")
            print(f"{en}: page {name} rect {x},{y} {w}x{h} offset {ox},{oy} cell {fx}x{fy} bbox-in-cell {cell.getbbox()}")
            found += 1
    pos += plen
print(f"found {found}/{len(want)}")
