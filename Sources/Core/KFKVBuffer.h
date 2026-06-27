
#ifndef KFKV_MMBUFFER_H
#define KFKV_MMBUFFER_H
#ifdef __cplusplus

#include "KFKVPredef.h"

#include <cstdint>
#include <cstdlib>
#include <cstddef>

namespace kfkv {

enum KFKVBufferCopyFlag : bool {
    KFKVBufferCopy = false,
    KFKVBufferNoCopy = true,
};

#pragma pack(push, 1)

#ifndef KFKV_DISABLE_CRYPT
struct KeyValueHolderCrypt;
#endif

#ifdef KFKV_APPLE
#ifdef __OBJC__
using NSDataType = NSData;
#else
using NSDataType = void;
#endif
#endif // KFKV_APPLE

class KFKV_EXPORT KFKVBuffer {
    enum KFKVBufferType : uint8_t {
        KFKVBufferType_Small,  // store small buffer in stack memory
        KFKVBufferType_Normal, // store in heap memory
    };
    KFKVBufferType type;

    union {
        struct {
            KFKVBufferCopyFlag isNoCopy;
            size_t size;
            void *ptr;
#ifdef KFKV_APPLE
            __unsafe_unretained NSDataType *m_data;
#endif
        };
        struct {
            uint8_t paddedSize;
            // make at least 10 bytes to hold all primitive types (negative int32, int64, double etc.) on 32 bit device
            // on 64 bit device it's guaranteed larger than 10 bytes
            uint8_t paddedBuffer[10];
        };
    };

    static constexpr size_t SmallBufferSize() {
        return sizeof(KFKVBuffer) - offsetof(KFKVBuffer, paddedBuffer);
    }

public:
    explicit KFKVBuffer(size_t length = 0);
    KFKVBuffer(void *source, size_t length, KFKVBufferCopyFlag flag = KFKVBufferCopy);
#ifdef KFKV_APPLE
    explicit KFKVBuffer(NSDataType *data, KFKVBufferCopyFlag flag = KFKVBufferCopy);

    NSDataType *toNSData(bool transferOwnerShip);
#endif

    KFKVBuffer(KFKVBuffer &&other) noexcept;
    KFKVBuffer(KFKVBuffer &&other, size_t length) noexcept;
    KFKVBuffer &operator=(KFKVBuffer &&other) noexcept;

    ~KFKVBuffer();

    bool isStoredOnStack() const { return (type == KFKVBufferType_Small); }

    void *getPtr() const { return isStoredOnStack() ? (void *) paddedBuffer : ptr; }

    size_t length() const { return isStoredOnStack() ? paddedSize : size; }

    // transfer ownership to others
    void detach();

    // compare two KFKVBuffer
    bool operator==(const KFKVBuffer& other) const;

    // those are expensive, just forbid it for possibly misuse
    explicit KFKVBuffer(const KFKVBuffer &other) = delete;
    KFKVBuffer &operator=(const KFKVBuffer &other) = delete;

#ifndef KFKV_DISABLE_CRYPT
    friend KeyValueHolderCrypt;
#endif
};

#pragma pack(pop)

} // namespace kfkv

#endif
#endif //KFKV_MMBUFFER_H
