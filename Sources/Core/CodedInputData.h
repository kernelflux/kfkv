
#ifndef KFKV_CODEDINPUTDATA_H
#define KFKV_CODEDINPUTDATA_H
#ifdef __cplusplus

#include "KFKVPredef.h"

#include "KeyValueHolder.h"
#include "KFKVBuffer.h"
#include <cstdint>

namespace kfkv {

class CodedInputData {
    uint8_t *const m_ptr;
    size_t m_size;
    size_t m_position;

    int8_t readRawByte();

    int32_t readRawVarint32();

    int32_t readRawLittleEndian32();

    int64_t readRawLittleEndian64();

public:
    CodedInputData(const void *oData, size_t length);

    bool isAtEnd() const { return m_position == m_size; };

    void seek(size_t addedSize);

    bool readBool();

    double readDouble();

    float readFloat();

    int64_t readInt64();

    uint64_t readUInt64();

    int32_t readInt32();

    uint32_t readUInt32();

    // exactly is like getValueSize(actualSize = true)
    KFKVBuffer readData(bool copy = true, bool exactly = false);
    void readData(KeyValueHolder &kvHolder);

    static KFKVBuffer readRealData(kfkv::KFKVBuffer & data);

    std::string readString();
    void readString(std::string &s);
    std::string readString(KeyValueHolder &kvHolder);
#ifdef __OBJC__
    NSString *readNSString();
    NSString *readNSString(KeyValueHolder &kvHolder);
    NSData *readNSData();
#endif
};

} // namespace kfkv

#endif
#endif //KFKV_CODEDINPUTDATA_H
