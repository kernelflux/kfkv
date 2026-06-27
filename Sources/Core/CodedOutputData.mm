
#include "CodedOutputData.h"
#include "PBUtility.h"
#include <cstring>
#include <stdexcept>

#ifdef KFKV_APPLE
#endif // KFKV_APPLE

using namespace std;

namespace kfkv {

CodedOutputData::CodedOutputData(void *ptr, size_t len) : m_ptr((uint8_t *) ptr), m_size(len), m_position(0) {
    KFKV_ASSERT(m_ptr);
}

uint8_t *CodedOutputData::curWritePointer() {
    return m_ptr + m_position;
}

void CodedOutputData::writeDouble(double value) {
    this->writeRawLittleEndian64(Float64ToInt64(value));
}

void CodedOutputData::writeFloat(float value) {
    this->writeRawLittleEndian32(Float32ToInt32(value));
}

void CodedOutputData::writeInt64(int64_t value) {
    this->writeRawVarint64(value);
}

void CodedOutputData::writeUInt64(uint64_t value) {
    writeRawVarint64(static_cast<int64_t>(value));
}

void CodedOutputData::writeInt32(int32_t value) {
    if (value >= 0) {
        this->writeRawVarint32(value);
    } else {
        this->writeRawVarint64(value);
    }
}

void CodedOutputData::writeUInt32(uint32_t value) {
    writeRawVarint32(static_cast<int32_t>(value));
}

void CodedOutputData::writeBool(bool value) {
    this->writeRawByte(static_cast<uint8_t>(value ? 1 : 0));
}

void CodedOutputData::writeData(const KFKVBuffer &value) {
    this->writeRawVarint32((int32_t) value.length());
    this->writeRawData(value);
}

void CodedOutputData::writeString(const string &value) {
    size_t numberOfBytes = value.size();
    this->writeRawVarint32((int32_t) numberOfBytes);
    if (m_position + numberOfBytes > m_size) {
        auto msg = "m_position: " + to_string(m_position) + ", numberOfBytes: " + to_string(numberOfBytes) +
                   ", m_size: " + to_string(m_size);
        throw out_of_range(msg);
    }
    memcpy(m_ptr + m_position, ((uint8_t *) value.data()), numberOfBytes);
    m_position += numberOfBytes;
}

size_t CodedOutputData::spaceLeft() {
    if (m_size <= m_position) {
        return 0;
    }
    return m_size - m_position;
}

void CodedOutputData::seek(size_t addedSize) {
    m_position += addedSize;

    if (m_position > m_size) {
        throw out_of_range("OutOfSpace");
    }
}

void CodedOutputData::reset() {
    m_position = 0;
}

size_t CodedOutputData::getPosition() {
    return m_position;
}

void CodedOutputData::setPosition(size_t position) {
    m_position = position;
}

void CodedOutputData::writeRawByte(uint8_t value) {
    if (m_position == m_size) {
        throw out_of_range("m_position: " + to_string(m_position) + " m_size: " + to_string(m_size));
        return;
    }

    m_ptr[m_position++] = value;
}

void CodedOutputData::writeRawData(const KFKVBuffer &data) {
    size_t numberOfBytes = data.length();
    if (m_position + numberOfBytes > m_size) {
        auto msg = "m_position: " + to_string(m_position) + ", numberOfBytes: " + to_string(numberOfBytes) +
                   ", m_size: " + to_string(m_size);
        throw out_of_range(msg);
    }
    memcpy(m_ptr + m_position, data.getPtr(), numberOfBytes);
    m_position += numberOfBytes;
}

void CodedOutputData::writeRawVarint32(int32_t value) {
    while (true) {
        if ((value & ~0x7f) == 0) {
            this->writeRawByte(static_cast<uint8_t>(value));
            return;
        } else {
            this->writeRawByte(static_cast<uint8_t>((value & 0x7F) | 0x80));
            value = logicalRightShift32(value, 7);
        }
    }
}

void CodedOutputData::writeRawVarint64(int64_t value) {
    while (true) {
        if ((value & ~0x7f) == 0) {
            this->writeRawByte(static_cast<uint8_t>(value));
            return;
        } else {
            this->writeRawByte(static_cast<uint8_t>((value & 0x7f) | 0x80));
            value = logicalRightShift64(value, 7);
        }
    }
}

void CodedOutputData::writeRawLittleEndian32(int32_t value) {
    this->writeRawByte(static_cast<uint8_t>((value) &0xff));
    this->writeRawByte(static_cast<uint8_t>((value >> 8) & 0xff));
    this->writeRawByte(static_cast<uint8_t>((value >> 16) & 0xff));
    this->writeRawByte(static_cast<uint8_t>((value >> 24) & 0xff));
}

void CodedOutputData::writeRawLittleEndian64(int64_t value) {
    this->writeRawByte(static_cast<uint8_t>((value) &0xff));
    this->writeRawByte(static_cast<uint8_t>((value >> 8) & 0xff));
    this->writeRawByte(static_cast<uint8_t>((value >> 16) & 0xff));
    this->writeRawByte(static_cast<uint8_t>((value >> 24) & 0xff));
    this->writeRawByte(static_cast<uint8_t>((value >> 32) & 0xff));
    this->writeRawByte(static_cast<uint8_t>((value >> 40) & 0xff));
    this->writeRawByte(static_cast<uint8_t>((value >> 48) & 0xff));
    this->writeRawByte(static_cast<uint8_t>((value >> 56) & 0xff));
}

} // namespace kfkv
