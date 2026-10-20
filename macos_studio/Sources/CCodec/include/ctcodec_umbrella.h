/* ctcodec.h — CCodec module umbrella.
 *
 * Prefers the real libctcodec header (written by the codec worker at
 * re_workspace/tools/libctcodec/ctcodec.h, reachable package-relatively via
 * the -I search path added in Package.swift). Falls back to the frozen
 * contract below when the real header does not exist yet, so this package
 * always compiles. Symbols are resolved at runtime via dlopen/dlsym
 * (see ChronoForgeCore/CodecBridge.swift), so a missing dylib never breaks
 * linking.
 */
#ifndef CTCODEC_UMBRELLA_H
#define CTCODEC_UMBRELLA_H

#if defined(__has_include)
#  if __has_include(<ctcodec.h>) && !defined(CTCODEC_FORCE_CONTRACT)
#    include <ctcodec.h>
#    define CTCODEC_USING_REAL_HEADER 1
#  endif
#endif

#ifndef CTCODEC_USING_REAL_HEADER
#define CTCODEC_USING_REAL_HEADER 0
#include <stdint.h>

/* Frozen contract (mirrors the codec worker's libctcodec):
 *   int ct_lzss_decompress(const uint8_t* src, int src_len,
 *                          uint8_t* dst, int dst_cap, int* out_written);
 *   int ct_lzss_compress  (const uint8_t* src, int src_len,
 *                          uint8_t* dst, int dst_cap, int* out_written,
 *                          int mode);            // mode 11 | 12
 * Both return 0 on success. */
int ct_lzss_decompress(const uint8_t* src, int src_len,
                       uint8_t* dst, int dst_cap, int* out_written);
int ct_lzss_compress(const uint8_t* src, int src_len,
                     uint8_t* dst, int dst_cap, int* out_written, int mode);

#endif /* CTCODEC_USING_REAL_HEADER */

/* Build markers exported by codec_anchor.c */
int ccodec_target_present(void);
int ccodec_using_real_header(void);

#endif /* CTCODEC_UMBRELLA_H */
