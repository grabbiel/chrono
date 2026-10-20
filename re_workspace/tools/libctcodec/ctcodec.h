/* ctcodec.h — Chrono Trigger data codec library (Phase 2+).
 *
 * Ground truth: ChronoRET asm/bankC3/bankC3.asm (Decomp_ToWram, org $C3:0002,
 * listing lines 1199-1520) + asm/include/constants_engine.inc lines 1333-1343.
 *
 * The Square LZSS variant used by Chrono Trigger (derived from the asm, not
 * from web folklore):
 *
 *   +0   u16le W  : segment 1's PACKED byte length (NOT the decompressed
 *                  size). Segment 1's items run from +2 to +2+W-1; its end
 *                  marker is at +2+W.  (bankC3.asm 1156-1157, 1209-1215)
 *   Items come in groups of 8 (Decomp_GroupSize). Each group starts with a
 *   control byte c, consumed LSB-first (LSR/BCS chain, lines 1274-1293):
 *     - c == 0 : run8 — the next 8 bytes are literal (lines 1242-1267).
 *     - c != 0 : one item per bit from bit 0 up; 0-bit = 1 literal byte;
 *       1-bit = back-reference, u16le v (low byte first), copied forward
 *       byte-by-byte from (output_pos - distance), overlaps repeating:
 *         lz12: distance = v & $0FFF (window 4096), length = (v >> 12) + 3
 *               (max 18)            [lines 1294-1314, masks $0FFF]
 *         lz11: distance = v & $07FF (window 2048), length = (v >> 11) + 3
 *               (max 34)            [lines 1490-1510, masks $07FF]
 *       min match length 3 (INC A; INC A on the shifted length + MVN's
 *       implicit +1: lines 1295-1302, 1314).
 *   End markers are checked only between groups, when the source offset
 *   equals the segment's end (lines 1271-1273): byte m then u16le offset.
 *     - m & $3F == 0: end of data (offset not read; final marker is 1 byte).
 *     - else: the next segment's end marker is at Src + offset (from the
 *       start), its items start right after the 3-byte record, and the
 *       next group with a nonzero control byte has only m & $3F items
 *       (lines 1323-1336).
 *   Mode: bits 6-7 of the FIRST end-marker byte: 0 = lz12 (12-bit offsets,
 *   4-bit lengths), nonzero = lz11 (11-bit offsets, 5-bit lengths). Later
 *   markers' bits 6-7 are not read. (lines 1224-1226; !Decomp_ModeMask = $C0,
 *   constants_engine.inc 1334-1335.)
 *
 * Output length is 16-bit (Y - Decomp_Dest): max 65535 bytes per pack.
 */
#ifndef CTCODEC_H
#define CTCODEC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- error codes (0 = success, negative = failure) ---- */
#define CT_OK                 0
#define CT_ERR_SRC_SMALL      (-1)  /* packed input shorter than its header */
#define CT_ERR_SRC_OVERFLOW   (-2)  /* stream tried to read past src_len */
#define CT_ERR_DST_OVERFLOW   (-3)  /* stream tried to write past dst_cap */
#define CT_ERR_BAD_DISTANCE   (-4)  /* back-reference distance 0 or ahead of output */
#define CT_ERR_BAD_MODE       (-5)  /* mode argument not 11 or 12 */

/* ============================================================
 * Section 1: LZSS (Phase 2.1) — IMPLEMENTED
 * ============================================================ */

/* Auto-detect the mode of a packed stream: reads u16le W at +0 and returns
 * 11 if src[2+W] & $C0 is nonzero, else 12. Negative CT_ERR_* on failure. */
int ct_lzss_detect_mode(const uint8_t *src, int src_len);

/* Decompress with mode auto-detected from the first end-marker byte.
 * *out_written = bytes produced. Returns CT_OK or a negative error.
 * dst_cap should be >= 65536 to accept any legal pack. */
int ct_lzss_decompress(const uint8_t *src, int src_len,
                       uint8_t *dst, int dst_cap, int *out_written);

/* Decompress with an explicit mode (11 or 12), overriding the marker bits.
 * Provided for forensics on malformed streams. */
int ct_lzss_decompress_mode(const uint8_t *src, int src_len,
                            uint8_t *dst, int dst_cap, int *out_written,
                            int mode);

/* Compress src[0..src_len) (at most 65535 bytes) with the original packer
 * (Okumura LZSS; reproduces every pack in the ROM byte for byte) and the
 * given mode (11 or 12). Emits header, whole groups in segment 1, the
 * 3-byte continuation marker + partial last group in segment 2 when the
 * item count is not a multiple of 8, and the 1-byte final end marker whose
 * bits 6-7 carry the mode. Returns CT_OK; *out_written = packed bytes. */
int ct_lzss_compress(const uint8_t *src, int src_len,
                     uint8_t *dst, int dst_cap, int *out_written,
                     int mode);

/* ============================================================
 * Section 2: Graphics — BGR555 color helpers — IMPLEMENTED
 * (SNES color word: bits 0-4 R, 5-9 G, 10-14 B, bit 15 unused)
 * ============================================================ */

/* One SNES BGR555 word -> 8-bit RGB (component c -> c*255/31 == c<<3|c>>2). */
void ct_bgr555_to_rgb(uint16_t word, uint8_t rgb[3]);
/* One SNES BGR555 word -> 8-bit RGBA (alpha 255). */
void ct_bgr555_to_rgba(uint16_t word, uint8_t rgba[4]);
/* One SNES BGR555 word -> RGB565 little-endian 2 bytes (for PNG via
 * converters that want 16-bit); reserved helper. */
void ct_bgr555_to_rgb565(uint16_t word, uint8_t out[2]);

/* ============================================================
 * Section 3: Graphics — tile / BMP / palette block decoding
 * (Phase 3) — RESERVED, NOT YET IMPLEMENTED.
 * Other workers: add prototypes here and definitions to ctcodec.c.
 * ============================================================ */
/* (empty — placeholder for ct_bmp4bpp_to_*, ct_palette_from_*, ...) */

/* ============================================================
 * Section 4: SPC700 BRR sample codec (Phase 5) — RESERVED,
 * NOT YET IMPLEMENTED.
 * ============================================================ */
/* (empty — placeholder for ct_brr_decode / ct_brr_encode.) */

#ifdef __cplusplus
}
#endif

#endif /* CTCODEC_H */
