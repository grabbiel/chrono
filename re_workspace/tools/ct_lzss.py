"""ct_lzss — ctypes wrapper for libctcodec.dylib (Chrono Trigger Square-LZSS).

Module name is 'ct_lzss' as specified for Phase 2 Step 2.1.

Public API:
    decompress(data: bytes, mode=None) -> bytes
        mode: None (auto-detect from the first end-marker byte's bits 6-7),
        or 'lz11'/'lz12' (or 11/12) to force.
    compress(data: bytes, mode='lz12') -> bytes
    detect_mode(data: bytes) -> 'lz11' | 'lz12'

Format (derived from ChronoRET bankC3.asm lines 1150-1520; see ctcodec.h):
  u16le segment-1 packed length; 8-item groups behind control bytes consumed
  LSB-first; zero control = 8 raw literals; set bit = u16le back-reference
  lz12: dist = v & $0FFF (window 4096), len = (v >> 12) + 3 (max 18)
  lz11: dist = v & $07FF (window 2048), len = (v >> 11) + 3 (max 34)
  between groups: end marker m|mode-bits + u16 next-segment end offset.
"""
import ctypes
import os

_DYLIB = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "libctcodec", "libctcodec.dylib")

_ERRORS = {
    -1: "input too small for a pack header",
    -2: "packed stream read past its end",
    -3: "stream wrote past the output buffer",
    -4: "invalid back-reference distance",
    -5: "mode must be 11 or 12",
}


class CtLzssError(ValueError):
    pass


_lib = ctypes.CDLL(_DYLIB)
_u8p = ctypes.POINTER(ctypes.c_uint8)

_lib.ct_lzss_decompress.restype = ctypes.c_int
_lib.ct_lzss_decompress.argtypes = [_u8p, ctypes.c_int, _u8p, ctypes.c_int,
                                    ctypes.POINTER(ctypes.c_int)]
_lib.ct_lzss_decompress_mode.restype = ctypes.c_int
_lib.ct_lzss_decompress_mode.argtypes = _lib.ct_lzss_decompress.argtypes + [ctypes.c_int]
_lib.ct_lzss_compress.restype = ctypes.c_int
_lib.ct_lzss_compress.argtypes = _lib.ct_lzss_decompress.argtypes + [ctypes.c_int]
_lib.ct_lzss_detect_mode.restype = ctypes.c_int
_lib.ct_lzss_detect_mode.argtypes = [_u8p, ctypes.c_int]
_lib.ct_bgr555_to_rgb.restype = None
_lib.ct_bgr555_to_rgb.argtypes = [ctypes.c_uint16, _u8p]
_lib.ct_bgr555_to_rgba.restype = None
_lib.ct_bgr555_to_rgba.argtypes = [ctypes.c_uint16, _u8p]


def _buf(data):
    data = bytes(data)
    if not data:
        return (ctypes.c_uint8 * 0)()
    return (ctypes.c_uint8 * len(data)).from_buffer_copy(data)


def _ptr(buf):
    return ctypes.cast(buf, _u8p)


def _norm_mode(mode):
    if mode is None:
        return None
    if isinstance(mode, int):
        if mode in (11, 12):
            return mode
    else:
        m = str(mode).lower().replace("lz", "").strip()
        if m in ("11", "12"):
            return int(m)
    raise CtLzssError("mode must be 'lz11', 'lz12', 11, 12, or None")


def _check(rc, out=None):
    if rc != 0:
        raise CtLzssError("libctcodec error %d: %s" % (rc, _ERRORS.get(rc, "unknown")))
    return out


def detect_mode(data: bytes) -> str:
    """Return 'lz11' or 'lz12' from bits 6-7 of the first end-marker byte."""
    data = bytes(data)
    src = _buf(data)
    rc = _lib.ct_lzss_detect_mode(_ptr(src), len(data))
    if rc < 0:
        _check(rc)
    return "lz%d" % rc


def decompress(data: bytes, mode=None) -> bytes:
    """Decompress a packed stream. mode=None auto-detects lz11/lz12."""
    data = bytes(data)
    m = _norm_mode(mode)
    src = _buf(data)
    # Output length is 16-bit in the game's loop (Y - Decomp_Dest): max 65535.
    dst = (ctypes.c_uint8 * 65536)()
    written = ctypes.c_int(0)
    if m is None:
        rc = _lib.ct_lzss_decompress(_ptr(src), len(data), _ptr(dst), 65536,
                                     ctypes.byref(written))
    else:
        rc = _lib.ct_lzss_decompress_mode(_ptr(src), len(data), _ptr(dst), 65536,
                                          ctypes.byref(written), m)
    _check(rc)
    return bytes(bytearray(dst)[:written.value])


def compress(data: bytes, mode="lz12") -> bytes:
    """Compress bytes into a Chrono Trigger pack of the given mode."""
    data = bytes(data)
    m = _norm_mode(mode)
    if m is None:
        m = 12
    src = _buf(data)
    cap = len(data) + len(data) // 4 + 64
    dst = (ctypes.c_uint8 * cap)()
    written = ctypes.c_int(0)
    rc = _lib.ct_lzss_compress(_ptr(src), len(data), _ptr(dst), cap,
                               ctypes.byref(written), m)
    if rc == -3 and written.value == 0:
        # buffer genuinely too small: grow once and retry
        cap = len(data) * 2 + 64
        dst = (ctypes.c_uint8 * cap)()
        rc = _lib.ct_lzss_compress(_ptr(src), len(data), _ptr(dst), cap,
                                   ctypes.byref(written), m)
    _check(rc)
    return bytes(bytearray(dst)[:written.value])


def bgr555_to_rgb(word: int):
    out = (ctypes.c_uint8 * 3)()
    _lib.ct_bgr555_to_rgb(word, out)
    return tuple(out)


def bgr555_to_rgba(word: int):
    out = (ctypes.c_uint8 * 4)()
    _lib.ct_bgr555_to_rgba(word, out)
    return tuple(out)
