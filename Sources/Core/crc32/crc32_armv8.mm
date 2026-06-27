
#include "Checksum.h"

#ifdef KFKV_USE_ARMV8_CRC32

#    ifdef CRC32
// nothing to do
#    elif KFKV_EMBED_ZLIB

static inline uint32_t _crc32Wrap(uint32_t crc, const uint8_t *buf, size_t len) {
    return static_cast<uint32_t>(zlib::crc32(crc, buf, static_cast<uInt>(len)));
}

CRC32_Func_t CRC32 = _crc32Wrap;

#    else
#        include <zlib.h>

static inline uint32_t _crc32Wrap(uint32_t crc, const uint8_t *buf, size_t len) {
    return static_cast<uint32_t>(::crc32(crc, buf, static_cast<uInt>(len)));
}

CRC32_Func_t CRC32 = _crc32Wrap;

#    endif

// targeting armv8 with crc instruction extension
#if defined(__GNUC__) && !defined(__clang__)
#    define TARGET_ARM_CRC __attribute__((target("+crc")))
#    define __builtin_arm_crc32b(a, b) __builtin_aarch64_crc32b(a, b)
#    define __builtin_arm_crc32h(a, b) __builtin_aarch64_crc32h(a, b)
#    define __builtin_arm_crc32w(a, b) __builtin_aarch64_crc32w(a, b)
#    define __builtin_arm_crc32d(a, b) __builtin_aarch64_crc32x(a, b)
#else
#    define TARGET_ARM_CRC __attribute__((target("crc")))
#endif

TARGET_ARM_CRC static inline uint32_t __crc32b(uint32_t a, uint8_t b) {
    return __builtin_arm_crc32b(a, b);
}

TARGET_ARM_CRC static inline uint32_t __crc32h(uint32_t a, uint16_t b) {
    return __builtin_arm_crc32h(a, b);
}

TARGET_ARM_CRC static inline uint32_t __crc32w(uint32_t a, uint32_t b) {
    return __builtin_arm_crc32w(a, b);
}

TARGET_ARM_CRC static inline uint32_t __crc32d(uint32_t a, uint64_t b) {
    return __builtin_arm_crc32d(a, b);
}

TARGET_ARM_CRC static inline uint32_t armv8_crc32_small(uint32_t crc, const uint8_t *buf, size_t len) {
    if (len >= sizeof(uint32_t)) {
        crc = __crc32w(crc, *(const uint32_t *) buf);
        buf += sizeof(uint32_t);
        len -= sizeof(uint32_t);
    }
    if (len >= sizeof(uint16_t)) {
        crc = __crc32h(crc, *(const uint16_t *) buf);
        buf += sizeof(uint16_t);
        len -= sizeof(uint16_t);
    }
    if (len >= sizeof(uint8_t)) {
        crc = __crc32b(crc, *(const uint8_t *) buf);
    }

    return crc;
}

namespace kfkv {

TARGET_ARM_CRC uint32_t armv8_crc32(uint32_t crc, const uint8_t *buf, size_t len) {

    crc = crc ^ 0xffffffffUL;

    // roundup to 8 byte pointer
    auto offset = std::min(len, (uintptr_t) buf & 7);
    if (offset) {
        crc = armv8_crc32_small(crc, buf, offset);
        buf += offset;
        len -= offset;
    }
    if (!len) {
        return crc ^ 0xffffffffUL;
    }

    // unroll to 8 * 8 byte per loop
    auto ptr64 = (const uint64_t *) buf;
    for (constexpr auto step = 8 * sizeof(uint64_t); len >= step; len -= step) {
        crc = __crc32d(crc, *ptr64++);
        crc = __crc32d(crc, *ptr64++);
        crc = __crc32d(crc, *ptr64++);
        crc = __crc32d(crc, *ptr64++);
        crc = __crc32d(crc, *ptr64++);
        crc = __crc32d(crc, *ptr64++);
        crc = __crc32d(crc, *ptr64++);
        crc = __crc32d(crc, *ptr64++);
    }

    for (constexpr auto step = sizeof(uint64_t); len >= step; len -= step) {
        crc = __crc32d(crc, *ptr64++);
    }

    if (len) {
        crc = armv8_crc32_small(crc, (const uint8_t *) ptr64, len);
    }

    return crc ^ 0xffffffffUL;
}

} // namespace kfkv

#endif // KFKV_USE_ARMV8_CRC32
