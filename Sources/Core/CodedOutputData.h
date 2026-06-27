
#ifndef KFKV_CODEDOUTPUTDATA_H
#define KFKV_CODEDOUTPUTDATA_H
#ifdef __cplusplus

#include "KFKVPredef.h"

#include "KFKVBuffer.h"
#include <cstdint>

namespace kfkv {

class CodedOutputData {
    uint8_t *const m_ptr;
    size_t m_size;
    size_t m_position;

public:
    CodedOutputData(void *ptr, size_t len);

    size_t spaceLeft();

    uint8_t *curWritePointer();

    void seek(size_t addedSize);

    void reset();

    size_t getPosition();

    void setPosition(size_t position);

    void writeRawByte(uint8_t value);

    void writeRawLittleEndian32(int32_t value);

    void writeRawLittleEndian64(int64_t value);

    void writeRawVarint32(int32_t value);

    void writeRawVarint64(int64_t value);

    void writeRawData(const KFKVBuffer &data);

    void writeDouble(double value);

    void writeFloat(float value);

    void writeInt64(int64_t value);

    void writeUInt64(uint64_t value);

    void writeInt32(int32_t value);

    void writeUInt32(uint32_t value);

    void writeBool(bool value);

    void writeData(const KFKVBuffer &value);

    void writeString(const std::string &value);
};

} // namespace kfkv

#endif
#endif //KFKV_CODEDOUTPUTDATA_H
