
#ifndef KeyValueHolder_hpp
#define KeyValueHolder_hpp
#ifdef __cplusplus

#include "KFKVBuffer.h"
#include "aes/AESCrypt.h"

namespace kfkv {

#pragma pack(push, 1)

struct KeyValueHolder {
    uint16_t computedKVSize; // internal use only
    uint16_t keySize;
    uint32_t valueSize;
    uint32_t offset;

    KeyValueHolder() = default;
    KeyValueHolder(uint32_t keyLength, uint32_t valueLength, uint32_t offset);

    KFKVBuffer toKFKVBuffer(const void *basePtr) const;
};

#ifndef KFKV_DISABLE_CRYPT

enum KeyValueHolderType : uint8_t {
    KeyValueHolderType_Direct, // store value directly
    KeyValueHolderType_Memory, // store value in the heap memory
    KeyValueHolderType_Offset, // store value by offset
};

// kv holder for encrypted kfkv
struct KeyValueHolderCrypt {
    KeyValueHolderType type = KeyValueHolderType_Direct;

    union {
        // store value by offset
        struct {
            uint8_t pbKeyValueSize; // size needed to encode keySize & valueSize
            uint16_t keySize;
            uint32_t valueSize;
            uint32_t offset;
            AESCryptStatus cryptStatus;
        };
        // store value directly
        struct {
            uint8_t paddedSize;
            uint8_t paddedValue[1];
        };
        // store value in the heap memory
        struct {
            uint32_t memSize;
            void *memPtr;
        };
    };

    static constexpr size_t SmallBufferSize() {
        return sizeof(KeyValueHolderCrypt) - offsetof(KeyValueHolderCrypt, paddedValue);
    }

    static constexpr size_t MediumBufferSize() {
        return 256;
    }

    static bool isValueStoredAsOffset(size_t valueSize) { return valueSize > MediumBufferSize(); }

    KeyValueHolderCrypt() = default;
    KeyValueHolderCrypt(const void *valuePtr, size_t valueLength);
    explicit KeyValueHolderCrypt(KFKVBuffer &&data);
    KeyValueHolderCrypt(uint32_t keyLength, uint32_t valueLength, uint32_t offset);

    KeyValueHolderCrypt(KeyValueHolderCrypt &&other) noexcept;
    KeyValueHolderCrypt &operator=(KeyValueHolderCrypt &&other) noexcept;
    void move(KeyValueHolderCrypt &&other) noexcept;

    ~KeyValueHolderCrypt();

    uint32_t realValueSize() const;

    KFKVBuffer toKFKVBuffer(const void *basePtr, const AESCrypt *crypter) const;

    std::tuple<uint32_t, uint32_t, AESCryptStatus *> toTuple() {
        return std::make_tuple(offset, pbKeyValueSize + keySize + valueSize, &cryptStatus);
    }

    // those are expensive, just forbid it for possibly misuse
    explicit KeyValueHolderCrypt(const KeyValueHolderCrypt &other) = delete;
    KeyValueHolderCrypt &operator=(const KeyValueHolderCrypt &other) = delete;

#ifdef KFKV_DEBUG
    static void testAESToKFKVBuffer();
#endif
};

#endif // KFKV_DISABLE_CRYPT

#pragma pack(pop)

} // namespace kfkv

#endif
#endif /* KeyValueHolder_hpp */
