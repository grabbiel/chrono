/* ctcodec.c — Chrono Trigger data codec (see ctcodec.h for the format).
 *
 * The decompressor is a faithful transcription of Decomp_ToWram as listed in
 * ChronoRET asm/bankC3/bankC3.asm lines 1199-1520 (the four loop copies
 * .m12_7E / .m12_7F / .m11_7E / .m11_7F differ only in the offset mask and
 * the WRAM bank; here they are one loop with a mode parameter).
 */
#include "ctcodec.h"
#include <string.h>
#include <stdlib.h>

#define CT_MODE_MASK        0xC0  /* !Decomp_ModeMask          (inc 1334) */
#define CT_GROUP_SIZE       8     /* !Decomp_GroupSize         (inc 1336) */
#define CT_MARKER_CNT_MASK  0x3F  /* !Decomp_MarkerCountMask   (inc 1337) */
#define CT_RUN_BYTES        8     /* !Decomp_RunBytes          (inc 1339) */
#define CT_OFFSET12_MASK    0x0FFF/* !Decomp_Offset12Mask      (inc 1340) */
#define CT_OFFSET11_MASK    0x07FF/* !Decomp_Offset11Mask      (inc 1341) */

static int u16le(const uint8_t *p) { return p[0] | (p[1] << 8); }

int ct_lzss_detect_mode(const uint8_t *src, int src_len)
{
    int w, seg_end;
    if (!src || src_len < 3) return CT_ERR_SRC_SMALL;
    w = u16le(src);                       /* segment 1 packed length */
    seg_end = 2 + w;                      /* bankC3.asm 1209-1215 */
    if (seg_end >= src_len) return CT_ERR_SRC_OVERFLOW; /* first marker unreadable */
    return (src[seg_end] & CT_MODE_MASK) ? 11 : 12;      /* bankC3.asm 1224-1226 */
}

int ct_lzss_decompress_mode(const uint8_t *src, int src_len,
                            uint8_t *dst, int dst_cap, int *out_written,
                            int mode)
{
    int x, y = 0, seg_end, group_left, ctrl, m;
    int mask, shift;

    if (!src || !dst || !out_written) return CT_ERR_SRC_SMALL;
    if (src_len < 3) return CT_ERR_SRC_SMALL;
    if (mode != 11 && mode != 12) return CT_ERR_BAD_MODE;

    mask  = (mode == 12) ? CT_OFFSET12_MASK : CT_OFFSET11_MASK;
    shift = (mode == 12) ? 12 : 11;

    seg_end = 2 + u16le(src);             /* X = 2; X + W  (asm 1209-1215) */
    if (seg_end > src_len) return CT_ERR_SRC_OVERFLOW;
    x = 2;
    group_left = CT_GROUP_SIZE;           /* entry .m12_7E_group (asm 1268-1270) */

    for (;;) {
        /* .next: end-marker check only between groups (asm 1271-1273) */
        if (x == seg_end) {
            if (x >= src_len) return CT_ERR_SRC_OVERFLOW;
            m = src[x] & CT_MARKER_CNT_MASK;          /* asm 1324-1325 */
            if (m == 0) break;                        /* end; offset not read (1326) */
            if (x + 3 > src_len) return CT_ERR_SRC_OVERFLOW;
            group_left = m;                           /* asm 1327 */
            seg_end = u16le(src + x + 1);             /* Src + offset, from start (1328-1331) */
            if (seg_end < x + 3) return CT_ERR_SRC_OVERFLOW; /* segments only move forward */
            x += 3;                                   /* asm 1332-1334 */
            continue;
        }
        if (x >= src_len) return CT_ERR_SRC_OVERFLOW;
        ctrl = src[x];                                /* control byte (asm 1274) */
        if (ctrl == 0) {                              /* run8 (asm 1242-1267) */
            if (x + 1 + CT_RUN_BYTES > src_len) return CT_ERR_SRC_OVERFLOW;
            if (y + CT_RUN_BYTES > dst_cap) return CT_ERR_DST_OVERFLOW;
            memcpy(dst + y, src + x + 1, CT_RUN_BYTES);
            x += CT_RUN_BYTES + 1;
            y += CT_RUN_BYTES;
            continue;                                 /* GroupLeft untouched (asm 1267) */
        }
        x++;                                          /* asm 1276 */
        /* item i tests bit i of c: the first BCS uses the carry of the
           LSR that stored CtrlBits = c>>1 (asm 1277-1279); later items
           LSR CtrlBits (asm 1287-1288). Net: LSB-first, bit 0 first. */
        for (;;) {
            if (ctrl & 1) {                           /* back-reference (asm 1294-1322) */
                int v, dist, len, j;
                if (x + 2 > src_len) return CT_ERR_SRC_OVERFLOW;
                v = u16le(src + x);                   /* low byte first */
                x += 2;
                len  = (v >> shift) + 3;              /* INC A; INC A + MVN's +1 (1295-1302,1314) */
                dist = v & mask;                      /* asm 1305 */
                if (dist == 0 || dist > y) return CT_ERR_BAD_DISTANCE;
                if (y + len > dst_cap) return CT_ERR_DST_OVERFLOW;
                for (j = 0; j < len; j++) {           /* forward byte copy: overlaps repeat */
                    dst[y] = dst[y - dist];           /* (asm header 1163-1164) */
                    y++;                              /* MVN advances Y one byte per byte copied */
                }
            } else {                                  /* literal (asm 1280-1283) */
                if (x + 1 > src_len) return CT_ERR_SRC_OVERFLOW;
                if (y + 1 > dst_cap) return CT_ERR_DST_OVERFLOW;
                dst[y++] = src[x++];
            }
            group_left--;                             /* .item_done (asm 1284-1288) */
            if (group_left == 0) { group_left = CT_GROUP_SIZE; break; } /* .group (1268-1270) */
            ctrl >>= 1;
        }
    }
    *out_written = y;                                 /* Decomp_OutLen = Y - Dest */
    return CT_OK;
}

int ct_lzss_decompress(const uint8_t *src, int src_len,
                       uint8_t *dst, int dst_cap, int *out_written)
{
    int mode = ct_lzss_detect_mode(src, src_len);
    if (mode < 0) return mode;
    return ct_lzss_decompress_mode(src, src_len, dst, dst_cap, out_written, mode);
}
/* ---- Compressor: the original packer ----
 *
 * Haruhiko Okumura's LZSS (LZSS.C, 1989) as Square ran it, identified by
 * ChronoRET (tools/c3pack.py, MIT) and confirmed here by rebuilding every
 * packed block in the ROM byte for byte (1,053 data-layer packs and all
 * 463 event-pack streams; manifests/lzss_verification.json):
 *   - binary search tree over a ring buffer of N bytes, look-ahead F
 *     (lz12: N 4096, F 18; lz11: N 2048, F 34), threshold 2, greedy; the
 *     tree decides between equal-length matches;
 *   - the ring starts zeroed with the first byte at 0 (r = 0, s = F) and no
 *     position before the data is in the tree; a reference stores the
 *     distance (r - match) & (N-1); control bit 1 = reference;
 *   - framing: whole groups of 8 items in segment 1; 1-7 leftover items go
 *     to segment 2 behind a (count | mode) marker with the final marker's
 *     offset, their unused control bits set; then the final marker (mode
 *     bits alone, $40 for lz11). */
typedef struct {
    int n, f, nil;
    uint8_t *text;
    int *lson, *rson, *dad;
    int match_pos, match_len;
} ctc_tree;

static void ctc_insert(ctc_tree *t, int r)
{
    int cmp = 1, i, p = t->n + 1 + t->text[r];
    t->rson[r] = t->lson[r] = t->nil;
    t->match_len = 0;
    for (;;) {
        if (cmp >= 0) {
            if (t->rson[p] != t->nil) p = t->rson[p];
            else { t->rson[p] = r; t->dad[r] = p; return; }
        } else {
            if (t->lson[p] != t->nil) p = t->lson[p];
            else { t->lson[p] = r; t->dad[r] = p; return; }
        }
        for (i = 1; i < t->f; i++)
            if ((cmp = t->text[r + i] - t->text[p + i]) != 0) break;
        if (i > t->match_len) {
            t->match_pos = p; t->match_len = i;
            if (i >= t->f) break;
        }
    }
    /* a full-length match replaces the old node */
    t->dad[r] = t->dad[p]; t->lson[r] = t->lson[p]; t->rson[r] = t->rson[p];
    t->dad[t->lson[p]] = r; t->dad[t->rson[p]] = r;
    if (t->rson[t->dad[p]] == p) t->rson[t->dad[p]] = r;
    else t->lson[t->dad[p]] = r;
    t->dad[p] = t->nil;
}

static void ctc_delete(ctc_tree *t, int p)
{
    int q;
    if (t->dad[p] == t->nil) return;
    if (t->rson[p] == t->nil) q = t->lson[p];
    else if (t->lson[p] == t->nil) q = t->rson[p];
    else {
        q = t->lson[p];
        if (t->rson[q] != t->nil) {
            while (t->rson[q] != t->nil) q = t->rson[q];
            t->rson[t->dad[q]] = t->lson[q];
            t->dad[t->lson[q]] = t->dad[q];
            t->lson[q] = t->lson[p];
            t->dad[t->lson[p]] = q;
        }
        t->rson[q] = t->rson[p];
        t->dad[t->rson[p]] = q;
    }
    t->dad[q] = t->dad[p];
    if (t->rson[t->dad[p]] == p) t->rson[t->dad[p]] = q;
    else t->lson[t->dad[p]] = q;
    t->dad[p] = t->nil;
}

/* Appends one packed byte; fails once cap is reached. */
#define CTC_PUT(b) do { if (*p >= cap) return CT_ERR_DST_OVERFLOW; dst[(*p)++] = (uint8_t)(b); } while (0)

/* One group: control byte (unused high bits set for a partial group), then
 * a literal byte or a little-endian reference word per item. */
static int ctc_emit_group(uint8_t *dst, int cap, int *p, const int *ref,
                          const int *val, int count)
{
    int i, ctrl = (0xFF << count) & 0xFF;
    for (i = 0; i < count; i++) if (ref[i]) ctrl |= 1 << i;
    CTC_PUT(ctrl);
    for (i = 0; i < count; i++) {
        if (ref[i]) {
            CTC_PUT(val[i] & 0xFF);             /* distance | (length-3) << shift */
            CTC_PUT(val[i] >> 8);
        } else {
            CTC_PUT(val[i]);
        }
    }
    return CT_OK;
}

int ct_lzss_compress(const uint8_t *src, int src_len,
                     uint8_t *dst, int dst_cap, int *out_written, int mode)
{
    ctc_tree t;
    int n, f, shift, modebits, len = src_len, nxt, r, s, i, nitems = 0, rc;
    int *ref = NULL, *val = NULL;

    if (!src || !dst || !out_written || src_len < 0) return CT_ERR_SRC_SMALL;
    if (mode != 11 && mode != 12) return CT_ERR_BAD_MODE;
    if (src_len > 0xFFFF) return CT_ERR_DST_OVERFLOW;  /* 16-bit output length */
    if (mode == 12) { n = 4096; f = 18; shift = 12; modebits = 0x00; }
    else            { n = 2048; f = 34; shift = 11; modebits = 0x40; }

    t.n = n; t.f = f; t.nil = n;
    t.text = (uint8_t *)calloc((size_t)(n + f - 1), 1);
    t.lson = (int *)malloc((size_t)(n + 1) * sizeof(int));
    t.rson = (int *)malloc((size_t)(n + 257) * sizeof(int));
    t.dad  = (int *)malloc((size_t)(n + 1) * sizeof(int));
    ref = (int *)malloc((size_t)(src_len + 1) * sizeof(int));
    val = (int *)malloc((size_t)(src_len + 1) * sizeof(int));
    if (!t.text || !t.lson || !t.rson || !t.dad || !ref || !val) { rc = CT_ERR_DST_OVERFLOW; goto done; }
    for (i = 0; i < n + 1; i++) t.lson[i] = t.dad[i] = n;
    for (i = 0; i < n + 257; i++) t.rson[i] = n;
    t.match_pos = t.match_len = 0;

    /* Items: ref[k] = 0 with val[k] = the byte, or 1 with val[k] = the word. */
    r = 0; s = f;
    if (len > f) len = f;
    memcpy(t.text, src, (size_t)len);
    nxt = len;
    if (len) ctc_insert(&t, r);
    while (len > 0) {
        int mlen = t.match_len < len ? t.match_len : len;
        if (mlen <= 2) {
            mlen = 1;
            ref[nitems] = 0; val[nitems] = t.text[r];
        } else {
            ref[nitems] = 1;
            val[nitems] = ((r - t.match_pos) & (n - 1)) | ((mlen - 3) << shift);
        }
        nitems++;
        for (i = 0; i < mlen && nxt < src_len; i++) {
            uint8_t c = src[nxt++];
            ctc_delete(&t, s);
            t.text[s] = c;
            if (s < f - 1) t.text[s + n] = c;
            s = (s + 1) & (n - 1); r = (r + 1) & (n - 1);
            ctc_insert(&t, r);
        }
        for (; i < mlen; i++) {
            ctc_delete(&t, s);
            s = (s + 1) & (n - 1); r = (r + 1) & (n - 1);
            if (--len) ctc_insert(&t, r);
        }
    }

    {
        int whole = nitems / CT_GROUP_SIZE * CT_GROUP_SIZE, rest = nitems - whole;
        int pos = 2, *p = &pos, cap = dst_cap, g, seg1;
        uint8_t *out = dst;
        if (cap < 2) { rc = CT_ERR_DST_OVERFLOW; goto done; }
        for (g = 0; g < whole; g += CT_GROUP_SIZE)
            if ((rc = ctc_emit_group(out, cap, p, ref + g, val + g, CT_GROUP_SIZE)) != CT_OK) goto done;
        seg1 = pos - 2;
        out[0] = (uint8_t)(seg1 & 0xFF); out[1] = (uint8_t)(seg1 >> 8);
        if (rest) {
            int marker = pos;
            pos += 3;
            if (pos > cap) { rc = CT_ERR_DST_OVERFLOW; goto done; }
            if ((rc = ctc_emit_group(out, cap, p, ref + whole, val + whole, rest)) != CT_OK) goto done;
            out[marker] = (uint8_t)(rest | modebits);
            out[marker + 1] = (uint8_t)(pos & 0xFF);
            out[marker + 2] = (uint8_t)(pos >> 8);
        }
        if (pos >= cap) { rc = CT_ERR_DST_OVERFLOW; goto done; }
        out[pos++] = (uint8_t)modebits;
        if (pos > 0x10000) { rc = CT_ERR_DST_OVERFLOW; goto done; }
        *out_written = pos;
        rc = CT_OK;
    }
done:
    free(t.text); free(t.lson); free(t.rson); free(t.dad); free(ref); free(val);
    return rc;
}

/* ---- BGR555 color helpers (SNES: r=bits0-4, g=5-9, b=10-14) ---- */
static uint8_t ctc_scale5(uint8_t c) { return (uint8_t)((c << 3) | (c >> 2)); }

void ct_bgr555_to_rgb(uint16_t word, uint8_t rgb[3])
{
    rgb[0] = ctc_scale5((uint8_t)(word & 0x1F));
    rgb[1] = ctc_scale5((uint8_t)((word >> 5) & 0x1F));
    rgb[2] = ctc_scale5((uint8_t)((word >> 10) & 0x1F));
}

void ct_bgr555_to_rgba(uint16_t word, uint8_t rgba[4])
{
    ct_bgr555_to_rgb(word, rgba);
    rgba[3] = 255;
}

void ct_bgr555_to_rgb565(uint16_t word, uint8_t out[2])
{
    int r = word & 0x1F, g = (word >> 5) & 0x1F, b = (word >> 10) & 0x1F;
    int v = (r << 11) | (g << 5) | b; /* standard RGB565 layout; 5-bit g fills the 6-bit field's top bits */
    out[0] = (uint8_t)(v & 0xFF); out[1] = (uint8_t)(v >> 8);
}

