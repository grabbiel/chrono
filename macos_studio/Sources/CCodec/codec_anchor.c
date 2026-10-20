/* CCodec target anchor. The codec itself lives in libctcodec.dylib and is
 * loaded at runtime; this TU only exposes a build marker so the target has
 * a compilable source file. */
#include "include/ctcodec_umbrella.h"

int ccodec_target_present(void) { return 1; }
int ccodec_using_real_header(void) { return CTCODEC_USING_REAL_HEADER; }
