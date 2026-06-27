
#include "CodedInputData.h"

#ifdef KFKV_APPLE

#    include "PBUtility.h"
#    include <stdexcept>


using namespace std;

namespace kfkv {

NSString *CodedInputData::readNSString() {
    int32_t size = this->readRawVarint32();
    if (size < 0) {
        throw length_error("InvalidProtocolBuffer negativeSize");
    }

    auto s_size = static_cast<size_t>(size);
    if (s_size <= m_size - m_position) {
        auto ptr = m_ptr + m_position;
        NSString *result = [[NSString alloc] initWithBytes:ptr length:s_size encoding:NSUTF8StringEncoding];
        m_position += s_size;
        return result;
    } else {
        throw out_of_range("InvalidProtocolBuffer truncatedMessage");
    }
}

NSString *CodedInputData::readNSString(KeyValueHolder &kvHolder) {
    kvHolder.offset = static_cast<uint32_t>(m_position);

    int32_t size = this->readRawVarint32();
    if (size < 0) {
        throw length_error("InvalidProtocolBuffer negativeSize");
    }

    auto s_size = static_cast<size_t>(size);
    if (s_size <= m_size - m_position) {
        kvHolder.keySize = static_cast<uint16_t>(s_size);

        auto ptr = m_ptr + m_position;
        NSString *result = [[NSString alloc] initWithBytes:ptr length:s_size encoding:NSUTF8StringEncoding];
        m_position += s_size;
        return result;
    } else {
        throw out_of_range("InvalidProtocolBuffer truncatedMessage");
    }
}

NSData *CodedInputData::readNSData() {
    int32_t size = this->readRawVarint32();
    if (size < 0) {
        throw length_error("InvalidProtocolBuffer negativeSize");
    }

    auto s_size = static_cast<size_t>(size);
    if (s_size <= m_size - m_position) {
        NSData *result = [NSData dataWithBytes:(m_ptr + m_position) length:s_size];
        m_position += s_size;
        return result;
    } else {
        throw out_of_range("InvalidProtocolBuffer truncatedMessage");
    }
}

} // namespace kfkv

#endif // KFKV_APPLE
