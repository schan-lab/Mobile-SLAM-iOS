// Zstandard decompressor (third_party/zstd, BSD), compiled as one unit like upstream's zstddeclib-in.c.
// Used to read zstd-compressed MCAP chunks (the ros2 bag record default).
#define DEBUGLEVEL 0
#define MEM_MODULE
#undef XXH_NAMESPACE
#define XXH_NAMESPACE ZSTD_
#undef XXH_PRIVATE_API
#define XXH_PRIVATE_API
#undef XXH_INLINE_ALL
#define XXH_INLINE_ALL
#define ZSTD_LEGACY_SUPPORT 0
#define ZSTD_STRIP_ERROR_STRINGS
#define ZSTD_TRACE 0
#define ZSTD_DISABLE_ASM 1

#define ZSTD_DEPS_NEED_MALLOC
#include "../../third_party/zstd/lib/common/zstd_deps.h"

#include "../../third_party/zstd/lib/common/debug.c"
#include "../../third_party/zstd/lib/common/entropy_common.c"
#include "../../third_party/zstd/lib/common/error_private.c"
#include "../../third_party/zstd/lib/common/fse_decompress.c"
#include "../../third_party/zstd/lib/common/zstd_common.c"

#include "../../third_party/zstd/lib/decompress/huf_decompress.c"
#include "../../third_party/zstd/lib/decompress/zstd_ddict.c"
#include "../../third_party/zstd/lib/decompress/zstd_decompress.c"
#include "../../third_party/zstd/lib/decompress/zstd_decompress_block.c"
