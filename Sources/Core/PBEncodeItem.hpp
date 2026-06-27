
#ifndef KFKV_PBENCODEITEM_HPP
#define KFKV_PBENCODEITEM_HPP
#ifdef  __cplusplus

#include "KFKVPredef.h"

#include "KFKVBuffer.h"
#include <cstdint>
#include <memory.h>

namespace kfkv {

enum PBEncodeItemType {
    PBEncodeItemType_None,
    PBEncodeItemType_Data,
    PBEncodeItemType_Container,
    PBEncodeItemType_String,
#ifdef KFKV_HAS_CPP20
    PBEncodeItemType_Int32,
    PBEncodeItemType_UInt32,
    PBEncodeItemType_Int64,
    PBEncodeItemType_UInt64,
//    PBEncodeItemType_Bool,
//    PBEncodeItemType_Float,
//    PBEncodeItemType_Double,
#endif // KFKV_HAS_CPP20
#ifdef KFKV_APPLE
    PBEncodeItemType_NSString,
    PBEncodeItemType_NSData,
    PBEncodeItemType_NSDate,
#endif
};

struct PBEncodeItem {
    PBEncodeItemType type;
    uint32_t compiledSize;
    uint32_t valueSize;
    union {
        const KFKVBuffer *bufferValue;
#ifdef KFKV_HAS_CPP20
//        bool boolValue;
        int32_t int32Value;
        int64_t int64Value;
        uint32_t uint32Value;
        uint64_t uint64Value;
#endif // KFKV_HAS_CPP20
        //        float floatValue;
//        double doubleValue;
        const std::string *strValue;
#ifdef KFKV_APPLE
        void *objectValue;
        void *tmpObjectValue; // this object should be released on dealloc
#endif
    } value;

    PBEncodeItem() : type(PBEncodeItemType_None), compiledSize(0), valueSize(0) { memset(&value, 0, sizeof(value)); }

#ifndef KFKV_APPLE
    // opt std::vector.push_back() on slow_path
    PBEncodeItem(PBEncodeItem &&other) = default;
#else
    // opt std::vector.push_back() on slow_path
    PBEncodeItem(PBEncodeItem &&other)
        : type(other.type), compiledSize(other.compiledSize), valueSize(other.valueSize), value(other.value) {
        // omit unnecessary CFRetain() & CFRelease()
        other.type = PBEncodeItemType_None;
    }

    ~PBEncodeItem() {
        if (type == PBEncodeItemType_NSString) {
            if (value.tmpObjectValue) {
                CFRelease(value.tmpObjectValue);
            }
        }
    }
#endif // KFKV_APPLE
};

} // namespace kfkv

#endif
#endif //KFKV_PBENCODEITEM_HPP
