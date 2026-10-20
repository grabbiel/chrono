#!/usr/bin/env python3
"""gen_fixture_assets.py — generate binary test fixtures for ChronoForgeCoreTests.

Writes:
  Tests/ChronoForgeCoreTests/Resources/TileGolden/4bpp_blob.bin      (planar tiles)
  Tests/ChronoForgeCoreTests/Resources/TileGolden/4bpp_indices.bin    (expected decode, python reference)
  Tests/ChronoForgeCoreTests/Resources/TileGolden/2bpp_blob.bin
  Tests/ChronoForgeCoreTests/Resources/TileGolden/2bpp_indices.bin
  Tests/ChronoForgeCoreTests/Resources/MyGame.ctproj/sprites/robo.png (indexed 4bpp, mode P)
  Tests/ChronoForgeCoreTests/Resources/MyGame.ctproj/tilesets/overworld.bin (planar 4bpp blob)
  Tests/ChronoForgeCoreTests/Resources/MyGame.ctproj/audio/samples/hit.brr  (BRR, python encoder = same recursions)
  Tests/ChronoForgeCoreTests/Resources/MyGame.ctproj/audio/samples/hit.wav

Reference implementations here are INDEPENDENT transcriptions (python), so the
Swift tests compare against a second implementation, not a copy of themselves.
"""
import os, random, struct, wave

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RES = os.path.join(ROOT, "Tests", "ChronoForgeCoreTests", "Resources")
FIX = os.path.join(RES, "MyGame.ctproj")

def wr(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)

# ---- tile golden (independent python decoder) ----
def decode_4bpp(blob):
    out = []
    for t in range(len(blob) // 32):
        base = t * 32
        for row in range(8):
            for col in range(8):
                idx = 0
                for p in range(4):
                    if blob[base + p * 8 + row] & (1 << (7 - col)):
                        idx |= 1 << p
                out.append(idx)
    return bytes(out)

def decode_2bpp(blob):
    out = []
    for t in range(len(blob) // 16):
        base = t * 16
        for row in range(8):
            for col in range(8):
                idx = 0
                for p in range(2):
                    if blob[base + p * 8 + row] & (1 << (7 - col)):
                        idx |= 1 << p
                out.append(idx)
    return bytes(out)

rnd = random.Random(0xC7C0C3)
blob4 = bytes(rnd.randrange(256) for _ in range(32 * 24))
wr(os.path.join(RES, "TileGolden", "4bpp_blob.bin"), blob4)
wr(os.path.join(RES, "TileGolden", "4bpp_indices.bin"), decode_4bpp(blob4))
blob2 = bytes(rnd.randrange(256) for _ in range(16 * 24))
wr(os.path.join(RES, "TileGolden", "2bpp_blob.bin"), blob2)
wr(os.path.join(RES, "TileGolden", "2bpp_indices.bin"), decode_2bpp(blob2))

# ---- indexed PNG writer (mode P, 4bpp) without pillow ----
import zlib
def png_indexed(path, w, h, depth, palette, indices):
    assert depth in (2, 4)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    spp = 8 // depth
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for xb in range(w // spp):
            b = 0
            for k in range(spp):
                b = (b << depth) | indices[y * w + xb * spp + k]
            raw.append(b)
    def chunk(typ, body):
        c = struct.pack(">I", len(body)) + typ + body
        return c + struct.pack(">I", zlib.crc32(typ + body) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", w, h, depth, 3, 0, 0, 0)
    plte = b"".join(struct.pack("BBB", (c >> 10) & 31, (c >> 5) & 31, c & 31) for c in palette)
    # PNG PLTE is sRGB 8-bit; expand BGR555 words
    plte = b"".join(bytes([((c & 31) << 3) | ((c & 31) >> 2),
                           (((c >> 5) & 31) << 3) | (((c >> 5) & 31) >> 2),
                           (((c >> 10) & 31) << 3) | (((c >> 10) & 31) >> 2)]) for c in palette)
    idat = zlib.compress(bytes(raw), 9)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"PLTE", plte)
                + chunk(b"IDAT", idat) + chunk(b"IEND", b""))

# sprite sheet: 16x16 px, 4bpp, 12 colors used
pal = [int(i * 4095 / 15) for i in range(16)]  # grayscale BGR555 words
idx = [(x * y) % 12 for y in range(16) for x in range(16)]
png_indexed(os.path.join(FIX, "sprites", "robo.png"), 16, 16, 4, pal, idx)

# tileset blob: 16 planar 4bpp tiles
ts_blob = bytes(rnd.randrange(256) for _ in range(32 * 16))
wr(os.path.join(FIX, "tilesets", "overworld.bin"), ts_blob)

# ---- BRR sample (independent python encoder, same hardware recursions) ----
rate = 32000
n = 16 * 40      # total samples
nblocks = n // 16
samples = []
for i in range(n):
    v = int(12000 * ((i % 32) - 16) / 16)  # triangle-ish
    samples.append(max(-32768, min(32767, v)))

def clamp16(v):
    return max(-32768, min(32767, v))

def filt(f, x, y1, y2):
    if f == 0: return x
    if f == 1: return x + y1 + ((-y1) >> 4)
    if f == 2: return x + ((61 * y1) >> 5) + ((-15 * y2) >> 4)
    return x + ((115 * y1) >> 6) + ((-13 * y2) >> 4)

blocks = bytearray()
y1 = y2 = 0
for b in range(nblocks):
    best = None
    for f in range(4):
        for s in range(13):
            ny1, ny2, nibs, err = y1, y2, [], 0
            for i in range(16):
                orig = samples[b * 16 + i]
                pred = filt(f, 0, ny1, ny2)
                bn, bd = 0, 1 << 60
                for cand in range(-8, 8):
                    x = (cand << s) >> 1 if s == 13 else cand << s
                    y = clamp16(x + pred)
                    d = abs(y - orig)
                    if d < bd: bd, bn = d, cand
                nibs.append(bn & 0xF)
                x = (bn << s) >> 1 if s == 13 else bn << s
                y = clamp16(x + pred)
                ny2, ny1 = ny1, y
                err = max(err, bd)
            if best is None or err < best[0]:
                best = (err, s, f, nibs, ny1, ny2)
    err, s, f, nibs, y1, y2 = best
    hdr = (s << 4) | (f << 2) | (1 if b == nblocks - 1 else 0)
    blocks.append(hdr)
    for i in range(0, 16, 2):
        blocks.append((nibs[i] << 4) | nibs[i + 1])

# Decode our own blocks to get the *reference output* the Swift decoder must
# reproduce byte-exactly (encoder quantization is lossy; originals != decoded).
decoded = []
y1 = y2 = 0
for b in range(nblocks):
    hdr = blocks[b * 9]
    s = hdr >> 4
    f = (hdr >> 2) & 3
    for i in range(16):
        nib = blocks[b * 9 + 1 + i // 2]
        nib = (nib >> 4) if i % 2 == 0 else (nib & 0xF)
        if nib >= 8: nib -= 16
        if s == 13: x = nib >> 1
        elif s == 14: x = 0
        else: x = nib << s
        y = clamp16(x + filt(f, 0, y1, y2))
        decoded.append(y)
        y2, y1 = y1, y

wr(os.path.join(FIX, "audio", "samples", "hit.brr"),
   struct.pack("<H", len(blocks)) + bytes(blocks))
with wave.open(os.path.join(FIX, "audio", "samples", "hit.wav"), "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
    w.writeframes(struct.pack("<%dh" % len(decoded), *decoded))

print("fixture assets written under", RES)
