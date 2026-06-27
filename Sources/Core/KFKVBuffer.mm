
#define NOMINMAX // undefine max/min

#include "KFKVBuffer.h"
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <utility>
#include <stdexcept>
#include <algorithm>

#ifdef KFKV_APPLE
#endif

using namespace std;

namespace kfkv {

KFKVBuffer::KFKVBuffer(size_t length) {
    if (length > SmallBufferSize()) {
        type = KFKVBufferType_Normal;
        isNoCopy = KFKVBufferCopy;
        size = length;
        ptr = malloc(size);
        if (!ptr) {
            throw std::runtime_error(strerror(errno));
        }
#ifdef KFKV_APPLE
        m_data = nil;
#endif
    } else {
        type = KFKVBufferType_Small;
        paddedSize = static_cast<uint8_t>(length);
    }
}

KFKVBuffer::KFKVBuffer(void *source, size_t length, KFKVBufferCopyFlag flag) : isNoCopy(flag) {
    if (isNoCopy == KFKVBufferCopy) {
        if (length > SmallBufferSize()) {
            type = KFKVBufferType_Normal;
            size = length;
            ptr = malloc(size);
            if (!ptr) {
                throw std::runtime_error(strerror(errno));
            }
            memcpy(ptr, source, size);
#ifdef KFKV_APPLE
            m_data = nil;
#endif
        } else {
            type = KFKVBufferType_Small;
            paddedSize = static_cast<uint8_t>(length);
            memcpy(paddedBuffer, source, length);
        }
    } else {
        type = KFKVBufferType_Normal;
        size = length;
        ptr = source;
#ifdef KFKV_APPLE
        m_data = nil;
#endif
    }
}

bool KFKVBuffer::operator==(const KFKVBuffer& other) const {
    if (this->length() != other.length()) {
        return false;
    }
    return !memcmp((uint8_t*)this->getPtr(), (uint8_t*)other.getPtr(), this->length());
}

#ifdef KFKV_APPLE
KFKVBuffer::KFKVBuffer(NSData *data, KFKVBufferCopyFlag flag)
    : type(KFKVBufferType_Normal), ptr((void *) data.bytes), size(data.length), isNoCopy(flag) {
    if (isNoCopy == KFKVBufferCopy) {
        m_data = (__bridge NSData *)CFBridgingRetain(data);
    } else {
        m_data = (__bridge NSData *)CFBridgingRetain(data);
    }
}
#endif

KFKVBuffer::KFKVBuffer(KFKVBuffer &&other) noexcept : type(other.type) {
    if (type == KFKVBufferType_Normal) {
        size = other.size;
        ptr = other.ptr;
        isNoCopy = other.isNoCopy;
#ifdef KFKV_APPLE
        m_data = other.m_data;
#endif
        other.detach();
    } else {
        paddedSize = other.paddedSize;
        memcpy(paddedBuffer, other.paddedBuffer, paddedSize);
    }
}

KFKVBuffer::KFKVBuffer(KFKVBuffer &&other, size_t length) noexcept : type(other.type) {
    if (type == KFKVBufferType_Normal) {
        size = std::min(other.size, length);
        ptr = other.ptr;
        isNoCopy = other.isNoCopy;
#ifdef KFKV_APPLE
        m_data = other.m_data;
#endif
        other.detach();
    } else {
        paddedSize = std::min(other.paddedSize, static_cast<uint8_t>(length));
        memcpy(paddedBuffer, other.paddedBuffer, paddedSize);
    }
}

KFKVBuffer &KFKVBuffer::operator=(KFKVBuffer &&other) noexcept {
    if (type == KFKVBufferType_Normal) {
        if (other.type == KFKVBufferType_Normal) {
            std::swap(isNoCopy, other.isNoCopy);
            std::swap(size, other.size);
            std::swap(ptr, other.ptr);
#ifdef KFKV_APPLE
            std::swap(m_data, other.m_data);
#endif
        } else {
            type = KFKVBufferType_Small;
            if (isNoCopy == KFKVBufferCopy) {
#ifdef KFKV_APPLE
                if (m_data) {
                    if (isNoCopy == KFKVBufferCopy) {
                        CFRelease((__bridge CFTypeRef)m_data);
                    }
                } else if (ptr) {
                    free(ptr);
                }
#else
                if (ptr) {
                    free(ptr);
                }
#endif
            }
            paddedSize = other.paddedSize;
            memcpy(paddedBuffer, other.paddedBuffer, paddedSize);
        }
    } else {
        if (other.type == KFKVBufferType_Normal) {
            type = KFKVBufferType_Normal;
            isNoCopy = other.isNoCopy;
            size = other.size;
            ptr = other.ptr;
#ifdef KFKV_APPLE
            m_data = other.m_data;
#endif
            other.detach();
        } else {
            paddedSize = other.paddedSize;
            memcpy(paddedBuffer, other.paddedBuffer, other.paddedSize);
        }
    }

    return *this;
}

KFKVBuffer::~KFKVBuffer() {
    if (isStoredOnStack()) {
        return;
    }

#ifdef KFKV_APPLE
    if (m_data) {
        if (isNoCopy == KFKVBufferCopy) {
            CFRelease((__bridge CFTypeRef)m_data);
        }
        return;
    }
#endif

    if (isNoCopy == KFKVBufferCopy && ptr) {
        free(ptr);
    }
}

void KFKVBuffer::detach() {
    // type = KFKVBufferType_Small;
    // paddedSize = 0;
    auto memsetPtr = (size_t *) &type;
    *memsetPtr = 0;
}

#ifdef KFKV_APPLE
NSData *KFKVBuffer::toNSData(bool transferOwnerShip) {
    if (!transferOwnerShip) {
        if (m_data) {
            return m_data;
        } else {
            return [NSData dataWithBytesNoCopy:getPtr() length:length() freeWhenDone:NO];
        }
    }
    if (m_data != nil) {
        NSData *result = CFBridgingRelease((__bridge CFTypeRef)m_data);
        m_data = nil;
        return result;
    }
    if (isStoredOnStack()) {
        return [NSData dataWithBytes:getPtr() length:length()];
    } else {
        if (isNoCopy == KFKVBufferNoCopy) {
            return [NSData dataWithBytesNoCopy:getPtr() length:length() freeWhenDone:NO];
        } else {
            auto result = [NSData dataWithBytesNoCopy:getPtr() length:length()];
            detach();
            return result;
        }
    }
}
#endif

} // namespace kfkv
