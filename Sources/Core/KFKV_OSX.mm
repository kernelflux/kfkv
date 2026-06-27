
#include "KFKVPredef.h"

#ifdef KFKV_APPLE

#    include "CodedInputData.h"
#    include "CodedOutputData.h"
#    include "InterProcessLock.h"
#    include "KFKV.h"
#    include "MemoryFile.h"
#    include "MiniPBCoder.h"
#    include "PBUtility.h"
#    include "ScopedLock.hpp"
#    include "ThreadLock.h"
#    include "aes/AESCrypt.h"
#    include <sys/utsname.h>
#    include <sys/sysctl.h>
#    include "KFKV_OSX.h"
#    include "KFKVLog.h"

#    ifdef KFKV_IOS
#        include <sys/mman.h>
#    endif

#    ifdef __aarch64__
#        include "crc32/Checksum.h"
#    endif


using namespace std;
using namespace kfkv;

extern ThreadLock *g_instanceLock;
extern KFKVPath_t g_rootDir;

KFKV_NAMESPACE_BEGIN

HybridString::HybridString(string_view cpp) {
    if (cpp.empty()) {
        str = nil;
    } else {
        str = [[NSString alloc] initWithBytesNoCopy:(void*)cpp.data() length:cpp.length() encoding:NSUTF8StringEncoding freeWhenDone:NO];
    }
}
HybridString::~HybridString() {
    
}

HybridStringCP::HybridStringCP(string_view cpp) {
    if (cpp.empty()) {
        str = nil;
    } else {
        str = [[NSString alloc] initWithBytes:(void*)cpp.data() length:cpp.length() encoding:NSUTF8StringEncoding];
    }
}
HybridStringCP::~HybridStringCP() {
    
}

bool KFKV::set(bool value, std::string_view key) {
    return set(value, key, m_expiredInSeconds);
}
bool KFKV::set(bool value, std::string_view key, uint32_t expireDuration) {
    HybridStringCP hybridKey = key;
    return set(value, hybridKey.str, expireDuration);
}

bool KFKV::set(int32_t value, std::string_view key) {
    return set(value, key, m_expiredInSeconds);
}
bool KFKV::set(int32_t value, std::string_view key, uint32_t expireDuration) {
    HybridStringCP hybridKey = key;
    return set(value, hybridKey.str, expireDuration);
}

bool KFKV::set(uint32_t value, std::string_view key) {
    return set(value, key, m_expiredInSeconds);
}
bool KFKV::set(uint32_t value, std::string_view key, uint32_t expireDuration) {
    HybridStringCP hybridKey = key;
    return set(value, hybridKey.str, expireDuration);
}

bool KFKV::set(int64_t value, std::string_view key) {
    return set(value, key, m_expiredInSeconds);
}
bool KFKV::set(int64_t value, std::string_view key, uint32_t expireDuration) {
    HybridStringCP hybridKey = key;
    return set(value, hybridKey.str, expireDuration);
}

bool KFKV::set(uint64_t value, std::string_view key) {
    return set(value, key, m_expiredInSeconds);
}
bool KFKV::set(uint64_t value, std::string_view key, uint32_t expireDuration) {
    HybridStringCP hybridKey = key;
    return set(value, hybridKey.str, expireDuration);
}

bool KFKV::set(float value, std::string_view key) {
    return set(value, key, m_expiredInSeconds);
}
bool KFKV::set(float value, std::string_view key, uint32_t expireDuration) {
    HybridStringCP hybridKey = key;
    return set(value, hybridKey.str, expireDuration);
}

bool KFKV::set(double value, std::string_view key) {
    return set(value, key, m_expiredInSeconds);
}
bool KFKV::set(double value, std::string_view key, uint32_t expireDuration) {
    HybridStringCP hybridKey = key;
    return set(value, hybridKey.str, expireDuration);
}

bool KFKV::set(const char *value, std::string_view key) {
    return set(value, key, m_expiredInSeconds);
}
bool KFKV::set(const char *value, std::string_view key, uint32_t expireDuration) {
    HybridStringCP hybridKey = key;
    return set(value, hybridKey.str, expireDuration);
}

bool KFKV::set(const std::string &value, std::string_view key) {
    return set(value, key, m_expiredInSeconds);
}
bool KFKV::set(const std::string &value, std::string_view key, uint32_t expireDuration) {
    HybridStringCP hybridKey = key;
    return set(value, hybridKey.str, expireDuration);
}

bool KFKV::set(std::string_view value, std::string_view key) {
    return set(value, key, m_expiredInSeconds);
}
bool KFKV::set(std::string_view value, std::string_view key, uint32_t expireDuration) {
    HybridStringCP hybridKey = key;
    return set(value, hybridKey.str, expireDuration);
}

bool KFKV::set(const kfkv::KFKVBuffer &value, std::string_view key) {
    return set(value, key, m_expiredInSeconds);
}
bool KFKV::set(const kfkv::KFKVBuffer &value, std::string_view key, uint32_t expireDuration) {
    HybridStringCP hybridKey = key;
    return set(value, hybridKey.str, expireDuration);
}

bool KFKV::set(const std::vector<std::string> &vector, std::string_view key) {
    return set(vector, key, m_expiredInSeconds);
}
bool KFKV::set(const std::vector<std::string> &vector, std::string_view key, uint32_t expireDuration) {
    HybridStringCP hybridKey = key;
    return set(vector, hybridKey.str, expireDuration);
}

bool KFKV::containsKey(std::string_view key) {
    HybridString hybridKey = key;
    return containsKey(hybridKey.str);
}

bool KFKV::removeValueForKey(std::string_view key) {
    HybridString hybridKey = key;
    return removeValueForKey(hybridKey.str);
}

bool KFKV::getBool(std::string_view key, bool defaultValue, bool *hasValue) {
    HybridString hybridKey = key;
    return getBool(hybridKey.str, defaultValue, hasValue);
}

int32_t KFKV::getInt32(std::string_view key, int32_t defaultValue, bool *hasValue) {
    HybridString hybridKey = key;
    return getInt32(hybridKey.str, defaultValue, hasValue);
}

uint32_t KFKV::getUInt32(std::string_view key, uint32_t defaultValue, bool *hasValue) {
    HybridString hybridKey = key;
    return getUInt32(hybridKey.str, defaultValue, hasValue);
}

int64_t KFKV::getInt64(std::string_view key, int64_t defaultValue, bool *hasValue) {
    HybridString hybridKey = key;
    return getInt64(hybridKey.str, defaultValue, hasValue);
}

uint64_t KFKV::getUInt64(std::string_view key, uint64_t defaultValue, bool *hasValue) {
    HybridString hybridKey = key;
    return getUInt64(hybridKey.str, defaultValue, hasValue);
}

float KFKV::getFloat(std::string_view key, float defaultValue, bool *hasValue) {
    HybridString hybridKey = key;
    return getFloat(hybridKey.str, defaultValue, hasValue);
}

double KFKV::getDouble(std::string_view key, double defaultValue, bool *hasValue) {
    HybridString hybridKey = key;
    return getDouble(hybridKey.str, defaultValue, hasValue);
}

bool KFKV::getString(std::string_view key, std::string &result, bool inplaceModification) {
    HybridString hybridKey = key;
    return getString(hybridKey.str, result, inplaceModification);
}

kfkv::KFKVBuffer KFKV::getBytes(std::string_view key) {
    HybridString hybridKey = key;
    return getBytes(hybridKey.str);
}

bool KFKV::getBytes(std::string_view key, kfkv::KFKVBuffer &result) {
    HybridString hybridKey = key;
    return getBytes(hybridKey.str, result);
}

kfkv::KFKVBuffer KFKV::getDataForKey(std::string_view key) {
    HybridString hybridKey = key;
    return getDataForKey(hybridKey.str);
}

bool KFKV::setDataForKey(kfkv::KFKVBuffer &&data, std::string_view key, bool isDataHolder) {
    HybridStringCP hybridKey = key;
    return setDataForKey(std::move(data), hybridKey.str, isDataHolder);
}

bool KFKV::getVector(std::string_view key, std::vector<std::string> &result) {
    HybridString hybridKey = key;
    return getVector(hybridKey.str, result);
}

#    ifdef KFKV_IOS

static bool g_isInBackground = false;

void KFKV::setIsInBackground(bool isInBackground) {
    if (!g_instanceLock) {
        return;
    }
    SCOPED_LOCK(g_instanceLock);

    g_isInBackground = isInBackground;
    KFKVInfo("g_isInBackground:%d", g_isInBackground);
}

bool KFKV::isInBackground() {
    if (!g_instanceLock) {
        return true;
    }
    SCOPED_LOCK(g_instanceLock);

    return g_isInBackground;
}

#    endif // KFKV_IOS

bool KFKV::set(NSObject<NSCoding> *__unsafe_unretained obj, KFKVKey_t key) {
    return set(obj, key, m_expiredInSeconds);
}

bool KFKV::set(NSObject<NSCoding> *__unsafe_unretained obj, KFKVKey_t key, uint32_t expireDuration) {
    if (isKeyEmpty(key)) {
        return false;
    }
    if (!obj) {
        removeValueForKey(key);
        return true;
    }

    NSData *tmpData = nil;
    if ([obj isKindOfClass:NSString.class]) {
        auto str = (NSString *) obj;
        tmpData = [str dataUsingEncoding:NSUTF8StringEncoding];
    } else if ([obj isKindOfClass:NSData.class]) {
        tmpData = (NSData *) obj;
    }
    if (tmpData) {
        // delay write the size needed for encoding tmpData
        // avoid memory copying
        if (kfkv_likely(!m_enableKeyExpire)) {
            return setDataForKey(KFKVBuffer(tmpData, KFKVBufferNoCopy), key, true);
        } else {
            KFKVBuffer data(tmpData, KFKVBufferNoCopy);
            if (data.length() > 0) {
                auto tmp = KFKVBuffer(pbKFKVBufferSize(data) + Fixed32Size);
                CodedOutputData output(tmp.getPtr(), tmp.length());
                output.writeData(data);
                auto time = (expireDuration != 0) ? getCurrentTimeInSecond() + expireDuration : 0;
                output.writeRawLittleEndian32(UInt32ToInt32(time));
                data = std::move(tmp);
            }
            return setDataForKey(std::move(data), key);
        }
    } else if ([obj isKindOfClass:NSDate.class]) {
        NSDate *oDate = (NSDate *) obj;
        double time = oDate.timeIntervalSince1970;
        return set(time, key, expireDuration);
    } else {
        /*if ([object conformsToProtocol:@protocol(NSCoding)])*/ {
            @try {
                NSError *error = nil;
                auto archived = [NSKeyedArchiver archivedDataWithRootObject:obj requiringSecureCoding:NO error:&error];
                if (error) {
                    KFKVError("fail to archive: %@", error);
                    return false;
                }
                if (archived.length > 0) {
                    if (kfkv_likely(!m_enableKeyExpire)) {
                        return setDataForKey(KFKVBuffer(archived, KFKVBufferNoCopy), key);
                    } else {
                        KFKVBuffer data(archived, KFKVBufferNoCopy);
                        if (data.length() > 0) {
                            auto tmp = KFKVBuffer(data.length() + Fixed32Size);
                            CodedOutputData output(tmp.getPtr(), tmp.length());
                            output.writeRawData(data); // NSKeyedArchiver has its own size management
                            auto time = (expireDuration != 0) ? getCurrentTimeInSecond() + expireDuration : 0;
                            output.writeRawLittleEndian32(UInt32ToInt32(time));
                            data = std::move(tmp);
                        }
                        return setDataForKey(std::move(data), key);
                    }
                }
            } @catch (NSException *exception) {
                KFKVError("exception: %@", exception.reason);
            }
        }
    }
    return false;
}

static id unSecureUnArchiveObjectWithData(NSData *data) {
    @try {
        NSError *error = nil;
        auto unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
        if (error) {
            KFKVError("fail to init unarchiver %@", error);
            return nil;
        }

        unarchiver.requiresSecureCoding = NO;
        id result = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
        
        return result;
    } @catch (NSException *exception) {
        KFKVError("exception: %@", exception.reason);
    }
    return nil;
}

NSObject *KFKV::getObject(KFKVKey_t key, Class cls) {
    if (isKeyEmpty(key) || !cls) {
        return nil;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    auto data = getDataForKey(key);
    if (data.length() > 0) {
        if (MiniPBCoder::isCompatibleClass(cls)) {
            try {
                auto result = MiniPBCoder::decodeObject(data, cls);
                return result;
            } catch (std::exception &exception) {
                KFKVError("%s", exception.what());
            } catch (...) {
                KFKVError("decode fail");
            }
        } else {
            if ([cls conformsToProtocol:@protocol(NSCoding)]) {
                auto tmp = [NSData dataWithBytesNoCopy:data.getPtr() length:data.length() freeWhenDone:NO];
                return unSecureUnArchiveObjectWithData(tmp);
            }
        }
    }
    return nil;
}

#    ifndef KFKV_DISABLE_CRYPT

pair<bool, KeyValueHolder>
KFKV::appendDataWithKey(const KFKVBuffer &data, KFKVKey_t key, const KeyValueHolderCrypt &kvHolder, bool isDataHolder) {
    if (kvHolder.type != KeyValueHolderType_Offset) {
        return appendDataWithKey(data, key, isDataHolder);
    }
    SCOPED_LOCK(m_exclusiveProcessLock);

    uint32_t keyLength = kvHolder.keySize;
    // size needed to encode the key
    size_t rawKeySize = keyLength + pbRawVarint32Size(keyLength);

    auto basePtr = (uint8_t *) m_file->getMemory() + Fixed32Size;
    KFKVBuffer keyData(rawKeySize);
    AESCrypt decrypter = m_crypter->cloneWithStatus(kvHolder.cryptStatus);
    decrypter.decrypt(basePtr + kvHolder.offset, keyData.getPtr(), rawKeySize);

    return doAppendDataWithKey(data, keyData, isDataHolder, keyLength);
}

pair<bool, KeyValueHolder>
KFKV::overrideDataWithKey(const KFKVBuffer &data, KFKVKey_t key, const KeyValueHolderCrypt &kvHolder, bool isDataHolder) {
    if (kvHolder.type != KeyValueHolderType_Offset) {
        return overrideDataWithKey(data, key, isDataHolder);
    }
    SCOPED_LOCK(m_exclusiveProcessLock);

    uint32_t keyLength = kvHolder.keySize;
    // size needed to encode the key
    size_t rawKeySize = keyLength + pbRawVarint32Size(keyLength);

    auto basePtr = (uint8_t *) m_file->getMemory() + Fixed32Size;
    KFKVBuffer keyData(rawKeySize);
    AESCrypt decrypter = m_crypter->cloneWithStatus(kvHolder.cryptStatus);
    decrypter.decrypt(basePtr + kvHolder.offset, keyData.getPtr(), rawKeySize);

    return doOverrideDataWithKey(data, keyData, isDataHolder, keyLength);
}
#    endif

NSArray *KFKV::allKeysObjC(bool filterExpire) {
    SCOPED_LOCK(m_lock);
    checkLoadData();

    if (kfkv_unlikely(filterExpire && m_enableKeyExpire)) {
        SCOPED_LOCK(m_exclusiveProcessLock);
        fullWriteback(nullptr, true);
    }

    NSMutableArray *keys = [NSMutableArray array];
    if (m_crypter) {
        for (const auto &pair : *m_dicCrypt) {
            [keys addObject:pair.first];
        }
    } else {
        for (const auto &pair : *m_dic) {
            [keys addObject:pair.first];
        }
    }
    return keys;
}

std::vector<std::string> KFKV::allKeys(bool filterExpire) {
    @autoreleasepool {
        auto arrKeys = allKeysObjC(filterExpire);
        std::vector<std::string> vec;
        for (NSString* str in arrKeys) {
            vec.push_back(str.UTF8String);
        }
        return vec;
    }
}

bool KFKV::removeValuesForKeys(NSArray *arrKeys) {
    if (isReadOnly()) {
        KFKVWarning("[%s] file readonly", m_mmapID.c_str());
        return false;
    }
    if (arrKeys.count == 0) {
        return true;
    }
    if (arrKeys.count == 1) {
        return removeValueForKey(arrKeys[0]);
    }

    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_exclusiveProcessLock);
    checkLoadData();

    size_t deleteCount = 0;
    if (m_crypter) {
        for (NSString *key in arrKeys) {
            auto itr = m_dicCrypt->find(key);
            if (itr != m_dicCrypt->end()) {
                auto oldKey = itr->first;
                m_dicCrypt->erase(itr);
                
                deleteCount++;
            }
        }
    } else {
        for (NSString *key in arrKeys) {
            auto itr = m_dic->find(key);
            if (itr != m_dic->end()) {
                auto oldKey = itr->first;
                m_dic->erase(itr);
                
                deleteCount++;
            }
        }
    }
    if (deleteCount > 0) {
        m_hasFullWriteback = false;

        return fullWriteback();
    }
    return true;
}

bool KFKV::removeValuesForKeys(const std::vector<std::string> &arrKeys) {
    if (arrKeys.empty()) {
        return true;
    }
    NSMutableArray* arr = [[NSMutableArray alloc] initWithCapacity:arrKeys.size()];
    for (auto& key : arrKeys) {
        [arr addObject:HybridString(key).str];
    }
    auto ret = removeValuesForKeys(arr);
    
    return ret;
}

void KFKV::enumerateKeys(EnumerateBlock block) {
    if (block == nil) {
        return;
    }
    SCOPED_LOCK(m_lock);
    checkLoadData();

    KFKVInfo("enumerate [%s] begin", m_mmapID.c_str());
    if (m_crypter) {
        for (const auto &pair : *m_dicCrypt) {
            BOOL stop = NO;
            block(pair.first, &stop);
            if (stop) {
                break;
            }
        }
    } else {
        for (const auto &pair : *m_dic) {
            BOOL stop = NO;
            block(pair.first, &stop);
            if (stop) {
                break;
            }
        }
    }
    KFKVInfo("enumerate [%s] finish", m_mmapID.c_str());
}

void GetAppleMachineInfo(int &device, int &version) {
    device = UnKnown;
    version = 0;

#    if 0
    struct utsname systemInfo = {};
    uname(&systemInfo);
    std::string machine(systemInfo.machine);
#    else
    size_t size;
    sysctlbyname("hw.machine", nullptr, &size, nullptr, 0);
    char *answer = (char *) malloc(size);
    sysctlbyname("hw.machine", answer, &size, nullptr, 0);
    std::string machine(answer);
    free(answer);
#    endif

    if (machine.find("PowerMac") != std::string::npos || machine.find("Power Macintosh") != std::string::npos) {
        device = PowerMac;
    } else if (machine.find("Mac") != std::string::npos || machine.find("Macintosh") != std::string::npos) {
        device = Mac;
    } else if (machine.find("iPhone") != std::string::npos) {
        device = iPhone;
    } else if (machine.find("iPod") != std::string::npos) {
        device = iPod;
    } else if (machine.find("iPad") != std::string::npos) {
        device = iPad;
    } else if (machine.find("AppleTV") != std::string::npos) {
        device = AppleTV;
    } else if (machine.find("AppleWatch") != std::string::npos) {
        device = AppleWatch;
    }
    auto pos = machine.find_first_of("0123456789");
    if (pos != std::string::npos) {
        version = std::atoi(machine.substr(pos).c_str());
    }
}

KFKV_NAMESPACE_END

#endif // KFKV_APPLE
