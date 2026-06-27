
#ifndef CodedInputDataCrypt_h
#define CodedInputDataCrypt_h
#ifdef __cplusplus

#include "KFKVPredef.h"

#include "KeyValueHolder.h"
#include "KFKVBuffer.h"
#include "aes/AESCrypt.h"
#include <cstdint>

#ifdef KFKV_DISABLE_CRYPT

namespace kfkv {
class CodedInputDataCrypt;
}

#else

namespace kfkv {

class CodedInputDataCrypt {
    uint8_t *const m_ptr;
    size_t m_size;
    size_t m_position;
    size_t m_decryptPosition; // position of text that has beed decrypted

    AESCrypt &m_decrypter;
    uint8_t *m_decryptBuffer; // internal decrypt buffer, grows by (n * AES_IV_LEN) bytes
    size_t m_decryptBufferSize;
    size_t m_decryptBufferPosition; // reader position in the buffer, synced with m_position
    size_t m_decryptBufferDecryptLength; // length of the buffer that has been used
    size_t m_decryptBufferDiscardPosition; // recycle position, any data before that can be discarded

    void consumeBytes(size_t length, bool discardPreData = false);
    void skipBytes(size_t length);
    void statusBeforeDecrypt(size_t rollbackSize, AESCryptStatus &status);

    int8_t readRawByte();

    int32_t readRawVarint32(bool discardPreData = false);

public:
    CodedInputDataCrypt(const void *oData, size_t length, AESCrypt &crypt);

    ~CodedInputDataCrypt();

    bool isAtEnd() { return m_position == m_size; };

    void seek(size_t addedSize);

    int32_t readInt32();

    void readData(KeyValueHolderCrypt &kvHolder);

    std::string readString(KeyValueHolderCrypt &kvHolder);
#ifdef __OBJC__
    NSString *readNSString(KeyValueHolderCrypt &kvHolder);
#endif
};

} // namespace kfkv

#endif // KFKV_DISABLE_CRYPT
#endif // __cplusplus
#endif /* CodedInputDataCrypt_h */
