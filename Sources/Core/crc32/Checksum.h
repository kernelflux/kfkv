
#ifndef CHECKSUM_H
#define CHECKSUM_H
#ifdef __cplusplus

#include "../KFKVPredef.h"
#include <cstdint>

#if KFKV_EMBED_ZLIB

#    include "zlib/zconf.h"

namespace zlib {

uLong crc32(uLong crc, const Bytef *buf, z_size_t len);

} // namespace zlib

#    define ZLIB_CRC32(crc, buf, len) zlib::crc32(crc, buf, len)

#else // KFKV_EMBED_ZLIB

#    include <zlib.h>
// some old version of zlib doesn't define z_size_t
#    ifndef z_size_t
       typedef size_t z_size_t;
#    endif
#    define ZLIB_CRC32(crc, buf, len) ::crc32(crc, buf, static_cast<uInt>(len))

#endif // KFKV_EMBED_ZLIB


#if defined(__aarch64__) && defined(__linux__)

#    define KFKV_USE_ARMV8_CRC32

namespace kfkv {
uint32_t armv8_crc32(uint32_t crc, const uint8_t *buf, size_t len);
}

#   ifdef KFKV_OHOS
// getauxval(AT_HWCAP) in OHOS returns wrong value, we just assume all OHOS device have crc32 instr
#       define CRC32 kfkv::armv8_crc32
#   else
// have to check CPU's instruction set dynamically
typedef uint32_t (*CRC32_Func_t)(uint32_t crc, const uint8_t *buf, size_t len);
extern CRC32_Func_t CRC32;
#   endif

#else // defined(__aarch64__) && defined(__linux__)

#    define CRC32(crc, buf, len) ZLIB_CRC32(crc, buf, len)

#endif // defined(__aarch64__) && defined(__linux__)

#endif // __cplusplus
#endif // CHECKSUM_H
