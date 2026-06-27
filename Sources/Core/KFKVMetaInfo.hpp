
#ifndef KFKV_KFKVMETAINFO_H
#define KFKV_KFKVMETAINFO_H
#ifdef __cplusplus

#include "aes/AESCrypt.h"
#include <cstdint>
#include <cstring>

namespace kfkv {

enum KFKVVersion : uint32_t {
    KFKVVersionDefault = 0,

    // record full write back count
    KFKVVersionSequence = 1,

    // store random iv for encryption
    KFKVVersionRandomIV = 2,

    // store actual size together with crc checksum, try to reduce file corruption
    KFKVVersionActualSize = 3,

    // store extra flags
    KFKVVersionFlag = 4,

    // preserved for internal use
    KFKVVersionPreserved = 5,

    // preserved for next use
    KFKVVersionNext = 6,

    // always large than next, a placeholder for error check
    KFKVVersionHolder = KFKVVersionNext + 1,
};

struct KFKVMetaInfo {
    uint32_t m_crcDigest = 0;
    uint32_t m_version = KFKVVersionSequence;
    uint32_t m_sequence = 0; // full write-back count
    uint8_t m_vector[AES_IV_LEN] = {};
    uint32_t m_actualSize = 0;

    // confirmed info: it's been synced to file
    struct {
        uint32_t lastActualSize = 0;
        uint32_t lastCRCDigest = 0;
        uint32_t _reserved[16] = {};
    } m_lastConfirmedMetaInfo;

    uint64_t m_flags = 0;

    enum KFKVMetaInfoFlag : uint64_t {
        EnableKeyExipre = 1 << 0,
    };
    bool hasFlag(KFKVMetaInfoFlag flag) { return (m_flags & flag) != 0; }
    void setFlag(KFKVMetaInfoFlag flag) { m_flags |= flag; }
    void unsetFlag(KFKVMetaInfoFlag flag) { m_flags &= ~flag; }

    void write(void *ptr) const {
        KFKV_ASSERT(ptr);
        memcpy(ptr, this, sizeof(KFKVMetaInfo));
    }

    void writeCRCAndActualSizeOnly(void *ptr) const {
        KFKV_ASSERT(ptr);
        auto other = (KFKVMetaInfo *) ptr;
        other->m_crcDigest = m_crcDigest;
        other->m_actualSize = m_actualSize;
    }

    void read(const void *ptr) {
        KFKV_ASSERT(ptr);
        memcpy(this, ptr, sizeof(KFKVMetaInfo));
    }
};

static_assert(sizeof(KFKVMetaInfo) <= (4 * 1024), "KFKVMetaInfo lager than one pagesize");

} // namespace kfkv

#endif
#endif //KFKV_KFKVMETAINFO_H
