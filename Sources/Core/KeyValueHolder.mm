
#include "KeyValueHolder.h"
#include "PBUtility.h"
#include "aes/AESCrypt.h"
#include <cerrno>
#include <cstring>
#include <stdexcept>

namespace kfkv {

KeyValueHolder::KeyValueHolder(uint32_t keyLength, uint32_t valueLength, uint32_t off)
    : keySize(static_cast<uint16_t>(keyLength)), valueSize(valueLength), offset(off) {
    computedKVSize = keySize + static_cast<uint16_t>(pbRawVarint32Size(keySize));
    computedKVSize += static_cast<uint16_t>(pbRawVarint32Size(valueSize));
}

KFKVBuffer KeyValueHolder::toKFKVBuffer(const void *basePtr) const {
    auto realPtr = (uint8_t *) basePtr + offset;
    realPtr += computedKVSize;
    return KFKVBuffer(realPtr, valueSize, KFKVBufferNoCopy);
}

#ifndef KFKV_DISABLE_CRYPT

KeyValueHolderCrypt::KeyValueHolderCrypt(const void *src, size_t length) {
    if (length <= SmallBufferSize()) {
        type = KeyValueHolderType_Direct;
        paddedSize = static_cast<uint8_t>(length);
        memcpy(paddedValue, src, length);
    } else {
        type = KeyValueHolderType_Memory;
        memSize = static_cast<uint32_t>(length);
        memPtr = malloc(length);
        if (!memPtr) {
            throw std::runtime_error(strerror(errno));
        }
        memcpy(memPtr, src, memSize);
    }
}

KeyValueHolderCrypt::KeyValueHolderCrypt(KFKVBuffer &&data) {
    if (data.type == KFKVBuffer::KFKVBufferType_Small) {
        static_assert(SmallBufferSize() >= KFKVBuffer::SmallBufferSize(), "KeyValueHolderCrypt can't hold KFKVBuffer");

        type = KeyValueHolderType_Direct;
        paddedSize = static_cast<uint8_t>(data.length());
        memcpy(paddedValue, data.getPtr(), data.length());
    } else {
        type = KeyValueHolderType_Memory;
        memSize = static_cast<uint32_t>(data.length());
#    ifdef KFKV_APPLE
        if (data.m_data != nil) {
            memPtr = malloc(memSize);
            if (!memPtr) {
                throw std::runtime_error(strerror(errno));
            }
            memcpy(memPtr, data.getPtr(), memSize);
            return;
        }
#    endif
        memPtr = data.getPtr();
        data.detach();
    }
}

KeyValueHolderCrypt::KeyValueHolderCrypt(uint32_t keyLength, uint32_t valueLength, uint32_t off)
    : type(KeyValueHolderType_Offset), keySize(static_cast<uint16_t>(keyLength)), valueSize(valueLength), offset(off) {

    pbKeyValueSize = static_cast<uint8_t>(pbRawVarint32Size(keySize) + pbRawVarint32Size(valueSize));
}

KeyValueHolderCrypt::KeyValueHolderCrypt(KeyValueHolderCrypt &&other) noexcept {
    this->move(std::move(other));
}

KeyValueHolderCrypt &KeyValueHolderCrypt::operator=(KeyValueHolderCrypt &&other) noexcept {
    if (type == KeyValueHolderType_Memory && memPtr) {
        free(memPtr);
    }
    this->move(std::move(other));
    return *this;
}

void KeyValueHolderCrypt::move(KeyValueHolderCrypt &&other) noexcept {
    if (other.type == KeyValueHolderType_Direct || other.type == KeyValueHolderType_Offset) {
        memcpy(reinterpret_cast<void*>(this), &other, sizeof(other));
    } else if (other.type == KeyValueHolderType_Memory) {
        type = KeyValueHolderType_Memory;
        memSize = other.memSize;
        memPtr = other.memPtr;
        other.memPtr = nullptr;
    }
}

KeyValueHolderCrypt::~KeyValueHolderCrypt() {
    if (type == KeyValueHolderType_Memory && memPtr) {
        free(memPtr);
    }
}

uint32_t KeyValueHolderCrypt::realValueSize() const {
    switch (type) {
        case KeyValueHolderType_Direct:
            return paddedSize;
        case KeyValueHolderType_Offset:
            return valueSize;
        case KeyValueHolderType_Memory:
            return memSize;
    }
    return 0;
}

// get decrypt data with [position, -1)
static KFKVBuffer decryptBuffer(AESCrypt &crypter, const KFKVBuffer &inputBuffer, size_t position) {
    size_t smallBuffer[16 / sizeof(size_t)];
    auto basePtr = (uint8_t *) inputBuffer.getPtr();
    auto ptr = basePtr;
    for (size_t index = sizeof(smallBuffer); index < position; index += sizeof(smallBuffer)) {
        crypter.decrypt(ptr, smallBuffer, sizeof(smallBuffer));
        ptr += sizeof(smallBuffer);
    }
    if (ptr < basePtr + position) {
        crypter.decrypt(ptr, smallBuffer, static_cast<size_t>(basePtr + position - ptr));
        ptr = basePtr + position;
    }
    size_t length = inputBuffer.length() - position;
    KFKVBuffer tmp(length);

    auto input = ptr;
    auto output = tmp.getPtr();
    crypter.decrypt(input, output, length);

    return tmp;
}

KFKVBuffer KeyValueHolderCrypt::toKFKVBuffer(const void *basePtr, const AESCrypt *crypter) const {
    if (type == KeyValueHolderType_Direct) {
        return KFKVBuffer((void *) paddedValue, paddedSize, KFKVBufferNoCopy);
    } else if (type == KeyValueHolderType_Memory) {
        return KFKVBuffer(memPtr, memSize, KFKVBufferNoCopy);
    } else {
        auto realPtr = (uint8_t *) basePtr + offset;
        auto position = static_cast<uint32_t>(pbKeyValueSize + keySize);
        auto realSize = position + valueSize;
        auto kvBuffer = KFKVBuffer(realPtr, realSize, KFKVBufferNoCopy);
        auto decrypter = crypter->cloneWithStatus(cryptStatus);
        return decryptBuffer(decrypter, kvBuffer, position);
    }
}

#endif // KFKV_DISABLE_CRYPT

} // namespace kfkv

#if !defined(KFKV_DISABLE_CRYPT) && defined(KFKV_DEBUG)
#    include "CodedInputData.h"
#    include "CodedOutputData.h"
#    include "KFKVLog.h"
#    include <ctime>

using namespace std;

namespace kfkv {

void KeyValueHolderCrypt::testAESToKFKVBuffer() {
    const uint8_t plainText[] = "Hello, OpenSSL-kfkv::KeyValueHolderCrypt::testAESToKFKVBuffer() with AES CFB 256.";
    constexpr size_t textLength = sizeof(plainText) - 1;

    const uint8_t key[] = "TheVeryLooooooooongAESKey";
    constexpr size_t keyLength = sizeof(key) - 1;
    auto aes256 = (keyLength > AES_KEY_LEN);

    uint8_t iv[AES_IV_LEN];
    srand((unsigned) time(nullptr));
    for (uint32_t i = 0; i < AES_IV_LEN; i++) {
        iv[i] = (uint8_t) rand();
    }
    AESCrypt crypt1(key, keyLength, iv, sizeof(iv), aes256);

    auto encryptText = new uint8_t[DEFAULT_MMAP_SIZE];
    memset(encryptText, 0, DEFAULT_MMAP_SIZE);
    CodedOutputData output(encryptText, DEFAULT_MMAP_SIZE);
    output.writeData(KFKVBuffer((void *) key, keyLength, KFKVBufferNoCopy));
    auto lengthOfValue = textLength + pbRawVarint32Size((uint32_t) textLength);
    output.writeRawVarint32((int32_t) lengthOfValue);
    output.writeData(KFKVBuffer((void *) plainText, textLength, KFKVBufferNoCopy));
    crypt1.encrypt(encryptText, encryptText, (size_t)(output.curWritePointer() - encryptText));

    AESCrypt decrypt(key, keyLength, iv, sizeof(iv), aes256);
    uint8_t smallBuffer[32];
    decrypt.decrypt(encryptText, smallBuffer, 5);
    auto keySize = CodedInputData(smallBuffer, 5).readUInt32();
    auto sizeOfKeySize = pbRawVarint32Size(keySize);
    auto position = sizeOfKeySize;
    decrypt.decrypt(encryptText + 5, smallBuffer + 5, static_cast<size_t>(sizeOfKeySize + keySize - 5));
    position += keySize;
    decrypt.decrypt(encryptText + position, smallBuffer + position, 5);
    auto valueSize = CodedInputData(smallBuffer + position, 5).readUInt32();
    // auto sizeOfValueSize = pbRawVarint32Size(valueSize);
    KeyValueHolderCrypt kvHolder(keySize, valueSize, 0);
    auto rollbackSize = position + 5;
    decrypt.statusBeforeDecrypt(encryptText + rollbackSize, smallBuffer + rollbackSize, rollbackSize,
                                kvHolder.cryptStatus);
    auto value = kvHolder.toKFKVBuffer(encryptText, &decrypt);
#    ifdef KFKV_APPLE
    KFKVInfo("testAESToKFKVBuffer: %@", CodedInputData((char *) value.getPtr(), value.length()).readNSString());
#    else
    KFKVInfo("testAESToKFKVBuffer: %s", CodedInputData((char *) value.getPtr(), value.length()).readString().c_str());
#    endif
    KFKVInfo("KFKVBuffer::SmallBufferSize() = %u, KeyValueHolderCrypt::SmallBufferSize() = %u",
             KFKVBuffer::SmallBufferSize(), KeyValueHolderCrypt::SmallBufferSize());

    delete[] encryptText;
}

} // namespace kfkv

#endif
