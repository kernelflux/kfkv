
#include "CodedInputDataCrypt.h"

#if defined(KFKV_APPLE) && !defined(KFKV_DISABLE_CRYPT)

#    include "PBUtility.h"
#    include <stdexcept>


using namespace std;

namespace kfkv {

NSString *CodedInputDataCrypt::readNSString(KeyValueHolderCrypt &kvHolder) {
    kvHolder.offset = static_cast<uint32_t>(m_position);

    int32_t size = this->readRawVarint32(true);
    if (size < 0) {
        throw length_error("InvalidProtocolBuffer negativeSize");
    }

    auto s_size = static_cast<size_t>(size);
    if (s_size <= m_size - m_position) {
        consumeBytes(s_size);

        kvHolder.keySize = static_cast<uint16_t>(s_size);

        auto ptr = m_decryptBuffer + m_decryptBufferPosition;
        NSString *result = [[NSString alloc] initWithBytes:ptr length:s_size encoding:NSUTF8StringEncoding];
        m_position += s_size;
        m_decryptBufferPosition += s_size;
        return result;
    } else {
        throw out_of_range("InvalidProtocolBuffer truncatedMessage");
    }
}

} // namespace kfkv

#endif // KFKV_APPLE && !KFKV_DISABLE_CRYPT
