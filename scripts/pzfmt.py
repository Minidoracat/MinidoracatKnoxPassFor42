"""PZPK v1 texture pack + tdef v1 tile definition: writer and reverse reader (B42 42.21.0).

Readers mirror the engine loaders line by line:
  .pack   TexturePackDevice.initMetaData/readPage (fileSystem/TexturePackDevice.java:80-150):
          "PZPK" + int version(1) + int pageCount; page = str name, int nEntries, int mask,
          nEntries x (str name, int x, y, w, h, ox, oy, fx, fy), int pngLen, png bytes.
          Strings are int length + bytes (TexturePackPage.ReadString :92-101); ints little-endian (:48-62).
          Sub-texture = page.split(x,y,w,h), offsetX/Y = ox/oy, widthOrig/heightOrig = fx/fy (TexturePackPage.java:131-142).
  .tiles  IsoWorld.LoadTileDefinitions (iso/IsoWorld.java:636-760):
          "tdef" + int version(1) + int nTilesets; tileset = line name, line imageName, int wTiles, int hTiles,
          int tilesetNumber (1..512 for mod files), int nTiles (<=512); tile = int nProps, nProps x (line key, line value).
          Lines end with LF; CR throws (IsoWorld.readString :611-630). Sprite name = <name>_<index> (:701),
          sprite id = 1048576 + (fileNumber-2)*262144 + (tilesetNumber-1)*512 + index (:632-634).
"""
from __future__ import annotations

import io
import struct

from PIL import Image


def _i(v: int) -> bytes:
    return struct.pack("<i", v)


def _s(s: str) -> bytes:
    b = s.encode("latin-1")
    return _i(len(b)) + b


def _line(s: str) -> bytes:
    if "\n" in s or "\r" in s:
        raise ValueError(f"line may not contain CR/LF: {s!r}")
    return s.encode("latin-1") + b"\n"


def write_pack(pages: list[tuple[str, Image.Image, list[tuple]]]) -> bytes:
    """pages: (page name, sheet image, [(entry, x, y, w, h, ox, oy, fx, fy), ...])."""
    out = b"PZPK" + _i(1) + _i(len(pages))
    for name, sheet, entries in pages:
        png = io.BytesIO()
        sheet.save(png, format="PNG", optimize=True)
        out += _s(name) + _i(len(entries)) + _i(1)
        for e in entries:
            out += _s(e[0]) + b"".join(_i(v) for v in e[1:])
        out += _i(len(png.getvalue())) + png.getvalue()
    return out


def write_tiles(tilesets: list[dict]) -> bytes:
    """tilesets: {name, image, w, h, number, tiles: [dict props per index]}."""
    out = b"tdef" + _i(1) + _i(len(tilesets))
    for ts in tilesets:
        out += _line(ts["name"]) + _line(ts["image"])
        out += _i(ts["w"]) + _i(ts["h"]) + _i(ts["number"]) + _i(len(ts["tiles"]))
        for props in ts["tiles"]:
            out += _i(len(props))
            for k, v in props.items():
                out += _line(k) + _line(v)
    return out


class _R:
    def __init__(self, data: bytes, pos: int = 0):
        self.d, self.p = data, pos

    def i(self) -> int:
        v = struct.unpack_from("<i", self.d, self.p)[0]
        self.p += 4
        return v

    def s(self) -> str:
        n = self.i()
        v = self.d[self.p:self.p + n].decode("latin-1")
        self.p += n
        return v

    def line(self) -> str:
        end = self.d.index(b"\n", self.p)
        raw = self.d[self.p:end]
        if b"\r" in raw:
            raise ValueError("CR in tdef line (engine throws IllegalStateException)")
        self.p = end + 1
        return raw.decode("latin-1")


def read_pack(data: bytes, decode_png: bool = True) -> list[dict]:
    r = _R(data)
    if data[:4] != b"PZPK":
        raise ValueError("version 0 (headerless) packs not handled")
    r.p = 4
    version = r.i()
    assert version == 1, version
    pages = []
    for _ in range(r.i()):
        name, n, mask = r.s(), r.i(), r.i()
        entries = [(r.s(), *[r.i() for _ in range(8)]) for _ in range(n)]
        plen = r.i()
        png = data[r.p:r.p + plen]
        r.p += plen
        img = Image.open(io.BytesIO(png)) if decode_png else None
        if img is not None:
            img.load()
            for e in entries:
                _, x, y, w, h, ox, oy, fx, fy = e
                assert 0 <= x and 0 <= y and x + w <= img.width and y + h <= img.height, e
                assert ox + w <= fx and oy + h <= fy, e
        pages.append({"name": name, "mask": mask, "entries": entries, "png_len": plen, "image": img})
    assert r.p == len(data), f"trailing bytes {len(data) - r.p}"
    return pages


def read_tiles(data: bytes, max_tilesets: int = 512, max_tiles: int = 512) -> list[dict]:
    r = _R(data)
    assert data[:4] == b"tdef", "not magic"
    r.p = 4
    assert r.i() == 1
    n = r.i()
    assert 0 <= n <= max_tilesets
    out = []
    for _ in range(n):
        name = r.line().strip()
        image = r.line()
        w, h, number, ntiles = r.i(), r.i(), r.i(), r.i()
        assert 1 <= number <= max_tilesets and 0 <= ntiles <= max_tiles, (name, number, ntiles)
        tiles = []
        for _ in range(ntiles):
            tiles.append({r.line().strip(): r.line().strip() for _ in range(r.i())})
        out.append({"name": name, "image": image, "w": w, "h": h, "number": number, "tiles": tiles})
    assert r.p == len(data), f"trailing bytes {len(data) - r.p}"
    return out


def sprite_id(file_number: int, tileset_number: int, index: int) -> int:
    if file_number == 1:
        return (tileset_number - 1) * 1024 + index
    return 1048576 + (file_number - 2) * 262144 + (tileset_number - 1) * 512 + index
