
#include "CodedInputData.h"
#include "CodedOutputData.h"
#include "InterProcessLock.h"
#include "KeyValueHolder.h"
#include "KFKVBuffer.h"
#include "KFKVLog.h"
#include "KFKVMetaInfo.hpp"
#include "KFKV_IO.h"
#include "KFKV_OSX.h"
#include "MemoryFile.h"
#include "MiniPBCoder.h"
#include "PBUtility.h"
#include "ScopedLock.hpp"
#include "ThreadLock.h"
#include "aes/AESCrypt.h"
#include "aes/openssl/openssl_aes.h"
#include "aes/openssl/openssl_md5.h"
#include "crc32/Checksum.h"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <unordered_set>
#include <cassert>

#if defined(__aarch64__) && defined(__linux__) && !defined (KFKV_OHOS)
#    include <asm/hwcap.h>
#    include <sys/auxv.h>
#endif

#ifdef KFKV_APPLE
#    include "KFKV_OSX.h"
#endif // KFKV_APPLE

using namespace std;
using namespace kfkv;

unordered_map<string, KFKV *> *g_instanceDic;
ThreadLock *g_instanceLock;
KFKVPath_t g_rootDir;
KFKVPath_t g_realRootDir;
static ThreadLock *g_namespaceLock;
static unordered_map<KFKVPath_t, KFKVPath_t> g_realRootMap;
size_t kfkv::DEFAULT_MMAP_SIZE;

KFKV_NAMESPACE_BEGIN

static KFKVPath_t encodeFilePath(const string &mmapID, const KFKVPath_t &rootDir);
bool endsWith(const KFKVPath_t &str, const KFKVPath_t &suffix);
KFKVPath_t filename(const KFKVPath_t &path);

#ifndef KFKV_ANDROID
KFKV::KFKV(const string &mmapID, const KFKVConfig &config)
    : m_mmapID(mmapID)
    , m_mode(config.mode)
    , m_path(mappedKVPathWithID(m_mmapID, config.rootPath, true))
    , m_crcPath(crcPathWithPath(m_path))
    , m_dic(nullptr)
    , m_dicCrypt(nullptr)
    , m_expectedCapacity(std::max<size_t>(DEFAULT_MMAP_SIZE, roundUp<size_t>(config.expectedCapacity, DEFAULT_MMAP_SIZE)))
    , m_file(new MemoryFile(m_path, m_expectedCapacity, isReadOnly(), true))
    , m_metaFile(new MemoryFile(m_crcPath, 0, isReadOnly(), !isMultiProcess()))
    , m_metaInfo(new KFKVMetaInfo())
    , m_crypter(nullptr)
    , m_lock(new ThreadLock())
    , m_fileLock(new FileLock(isMultiProcess() ? m_metaFile->getFd() : KFKVFileHandleInvalidValue))
    , m_sharedProcessLock(new InterProcessLock(m_fileLock, SharedLockType))
    , m_exclusiveProcessLock(new InterProcessLock(m_fileLock, ExclusiveLockType))
{
    m_actualSize = 0;
    m_output = nullptr;

#    ifndef KFKV_DISABLE_CRYPT
    auto cryptKey = config.cryptKey;
    if (cryptKey && !cryptKey->empty()) {
        m_dicCrypt = new KFKVMapCrypt();
        m_crypter = new AESCrypt(cryptKey->data(), cryptKey->length(), nullptr, 0, config.aes256);
    } else {
        m_dic = new KFKVMap();
    }
#    else
    m_dic = new KFKVMap();
#    endif

    m_needLoadFromFile = true;
    m_hasFullWriteback = false;

    m_crcDigest = 0;

    m_lock->initialize();
    m_sharedProcessLock->m_enable = isMultiProcess();
    m_exclusiveProcessLock->m_enable = isMultiProcess();

    m_recoverStrategic = config.recover;
    m_itemSizeLimit = config.itemSizeLimit;

    if (config.enableKeyExpire.has_value()) {
        configAutoExipreIfNeeded(config);
    }

    if (config.enableCompareBeforeSet) {
        enableCompareBeforeSet();
    }
}
#endif

KFKV::~KFKV() {
    clearMemoryCache();

    delete m_dic;
#ifndef KFKV_DISABLE_CRYPT
    delete m_dicCrypt;
    delete m_crypter;
#endif
    delete m_metaInfo;
    delete m_lock;
    delete m_fileLock;
    delete m_sharedProcessLock;
    delete m_exclusiveProcessLock;
#ifdef KFKV_ANDROID
#ifndef KFKV_OHOS
    delete m_sharedProcessModeLock;
    delete m_exclusiveProcessModeLock;
    delete m_fileModeLock;
#endif // !KFKV_OHOS
    delete m_sharedMigrationLock;
    delete m_fileMigrationLock;
#endif // KFKV_ANDROID
    delete m_metaFile;
    delete m_file;

    KFKVInfo("destruct [%s]", m_mmapID.c_str());
}

KFKV *KFKV::defaultKFKV(KFKVMode mode, const string *cryptKey, bool aes256) {
    auto config = KFKVConfig();
    config.mode = mode;
    config.aes256 = aes256;
    config.cryptKey = cryptKey;
    return kfkvWithID(DEFAULT_MMAP_ID, config);
}

KFKV *KFKV::defaultKFKV(const KFKVConfig &config) {
    return kfkvWithID(DEFAULT_MMAP_ID, config);
}

static void initialize() {
    g_instanceDic = new unordered_map<string, KFKV *>;
    g_instanceLock = new ThreadLock();
    g_instanceLock->initialize();

    kfkv::DEFAULT_MMAP_SIZE = kfkv::getPageSize();
    KFKVInfo("version %s, page size %d, arch %s", KFKV_VERSION, DEFAULT_MMAP_SIZE, KFKV_ABI);

    // get CPU status of ARMv8 extensions (CRC32, AES)
#if defined(__aarch64__) && defined(__linux__) && !defined (KFKV_OHOS)
    auto hwcaps = getauxval(AT_HWCAP);
#    ifndef KFKV_DISABLE_CRYPT
    if (hwcaps & HWCAP_AES) {
        openssl::AES_set_encrypt_key = openssl_aes_arm_set_encrypt_key;
        openssl::AES_set_decrypt_key = openssl_aes_arm_set_decrypt_key;
        openssl::AES_encrypt = openssl_aes_arm_encrypt;
        openssl::AES_decrypt = openssl_aes_arm_decrypt;
        KFKVInfo("armv8 AES instructions is supported");
    } else {
        KFKVInfo("armv8 AES instructions is not supported");
    }
#    endif // KFKV_DISABLE_CRYPT
#    ifdef KFKV_USE_ARMV8_CRC32
    if (hwcaps & HWCAP_CRC32) {
        CRC32 = kfkv::armv8_crc32;
        KFKVInfo("armv8 CRC32 instructions is supported");
    } else {
        KFKVInfo("armv8 CRC32 instructions is not supported");
    }
#    endif // KFKV_USE_ARMV8_CRC32
#endif     // __aarch64__ && defined(__linux__) && !defined (KFKV_OHOS)

#if defined(KFKV_DEBUG) && !defined(KFKV_DISABLE_CRYPT)
    // AESCrypt::testAESCrypt();
    // KeyValueHolderCrypt::testAESToKFKVBuffer();
#endif
}

static void ensureMinimalInitialize() {
    static ThreadOnceToken_t once_control = ThreadOnceUninitialized;
    ThreadLock::ThreadOnce(&once_control, initialize);
}

void KFKV::initializeKFKV(const KFKVPath_t &rootDir, KFKVLogLevel logLevel, kfkv::KFKVHandler *handler) {
    g_currentLogLevel = logLevel;
    g_handler = handler;

    ensureMinimalInitialize();

#ifdef KFKV_APPLE
    // crc32 instruction requires A10 chip, aka iPhone 7 or iPad 6th generation
    int device = 0, version = 0;
    GetAppleMachineInfo(device, version);
    KFKVInfo("Apple Device: %d, version: %d", device, version);
#endif

    if (g_rootDir.empty()) {
        g_rootDir = rootDir;
        // avoid operating g_realRootMap directly
        g_realRootDir = nameSpace(rootDir).getRootDir();
        mkPath(g_realRootDir);
    }
    const auto &rootDirStr = KFKVPath_t2String(g_realRootDir);
    KFKVInfo("root dir: %s", rootDirStr.c_str());
}

const KFKVPath_t &KFKV::getRootDir() {
    // for backword consistency we can't return g_realRootDir
    return g_rootDir;
}

#ifndef KFKV_ANDROID
KFKV *KFKV::getKFKVWithID(const std::string &mmapID, const KFKVConfig &config) {
    if (mmapID.empty() || !g_instanceLock) {
        return nullptr;
    }
    SCOPED_LOCK(g_instanceLock);

    auto rootPath = config.rootPath;
    auto mmapKey = mmapedKVKey(mmapID, rootPath, true);
    auto itr = g_instanceDic->find(mmapKey);
    if (itr != g_instanceDic->end()) {
        KFKV *kv = itr->second;
        return kv;
    }

    if (rootPath && (rootPath != &g_realRootDir) && !(config.mode & KFKV_READ_ONLY)) {
        KFKVPath_t specialPath = (*rootPath) + KFKV_PATH_SLASH + SPECIAL_CHARACTER_DIRECTORY_NAME;
        if (!isFileExist(specialPath)) {
            mkPath(specialPath);
        }
    }
    auto theRootDir = rootPath ? rootPath : &g_realRootDir;
    const auto &theRoot = KFKVPath_t2String(*theRootDir);
    KFKVInfo("prepare to load %s (id %s) from rootPath %s", mmapID.c_str(), mmapKey.c_str(), theRoot.c_str());

    auto kv = new KFKV(mmapID, config);
    kv->m_mmapKey = mmapKey;
    (*g_instanceDic)[mmapKey] = kv;
    return kv;
}
#endif

KFKV *KFKV::kfkvWithID(const string &mmapID, KFKVMode mode, const string *cryptKey, const KFKVPath_t *rootPath, size_t expectedCapacity, bool aes256) {
    KFKVConfig config;
    config.mode = mode;
#ifndef KFKV_DISABLE_CRYPT
    config.aes256 = aes256;
    config.cryptKey = cryptKey;
#endif
    config.rootPath = rootPath;
    config.expectedCapacity = expectedCapacity;

    return kfkvWithID(mmapID, config);
}

KFKV *KFKV::kfkvWithID(const std::string &mmapID, const KFKVConfig &config) {
    if (mmapID.empty() || !g_instanceLock) {
        return nullptr;
    }
    auto ns = config.rootPath ? nameSpace(*config.rootPath) : defaultNameSpace();

    auto newConfig = config;
    newConfig.rootPath = &ns.m_rootDir;
    return getKFKVWithID(mmapID, newConfig);
}

void KFKV::onExit() {
    if (!g_instanceLock) {
        return;
    }
    SCOPED_LOCK(g_instanceLock);

    for (auto &pair : *g_instanceDic) {
        KFKV *kv = pair.second;
        kv->sync();
        kv->clearMemoryCache();
        delete kv;
        pair.second = nullptr;
    }

    delete g_instanceDic;
    g_instanceDic = nullptr;
}

const string &KFKV::mmapID() const {
    return m_mmapID;
}

void KFKV::notifyContentChanged() {
    if (g_handler) {
        g_handler->onContentChangedByOuterProcess(m_mmapID);
    }
}

void KFKV::notifyContentLoaded() {
    if (g_handler) {
        g_handler->onKFKVContentLoadSuccessfully(m_mmapID);
    }
}

void KFKV::checkContentChanged() {
    SCOPED_LOCK(m_lock);
    checkLoadData();
}

void KFKV::clearMemoryCache(bool keepSpace) {
    SCOPED_LOCK(m_lock);
    if (m_needLoadFromFile) {
        return;
    }
    KFKVInfo("clearMemoryCache [%s]", m_mmapID.c_str());
    m_needLoadFromFile = true;
    m_hasFullWriteback = false;

    clearDictionary(m_dic);
#ifndef KFKV_DISABLE_CRYPT
    clearDictionary(m_dicCrypt);
    if (m_crypter) {
        if (m_metaInfo->m_version >= KFKVVersionRandomIV) {
            m_crypter->resetIV(m_metaInfo->m_vector, sizeof(m_metaInfo->m_vector));
        } else {
            m_crypter->resetIV();
        }
    }
#endif

    delete m_output;
    m_output = nullptr;

    if (!keepSpace) {
        m_file->clearMemoryCache();
    }
    // inter-process lock rely on MetaFile's fd, never close it
    // m_metaFile->clearMemoryCache();
    m_actualSize = 0;
    m_metaInfo->m_crcDigest = 0;
}

void KFKV::close() {
    KFKVInfo("close [%s]", m_mmapID.c_str());
    SCOPED_LOCK(g_instanceLock);
    m_lock->lock();

    auto itr = g_instanceDic->find(m_mmapKey);
    if (itr != g_instanceDic->end()) {
        g_instanceDic->erase(itr);
    }
    delete this;
}

#ifndef KFKV_DISABLE_CRYPT

string KFKV::cryptKey() const {
    SCOPED_LOCK(m_lock);

    if (m_crypter) {
        char key[AES256_KEY_LEN];
        m_crypter->getKey(key);
        return {key, strnlen(key, AES256_KEY_LEN)};
    }
    return "";
}

void KFKV::checkReSetCryptKey(const string *cryptKey, bool aes256) {
    SCOPED_LOCK(m_lock);

    if (m_crypter) {
        if (cryptKey && !cryptKey->empty()) {
            string oldKey = this->cryptKey();
            if (oldKey != *cryptKey) {
                KFKVInfo("setting new aes key");
                delete m_crypter;
                auto ptr = cryptKey->data();
                m_crypter = new AESCrypt(ptr, cryptKey->length(), nullptr, 0, aes256);

                checkLoadData();
            } else {
                // nothing to do
            }
        } else {
            KFKVInfo("reset aes key");
            delete m_crypter;
            m_crypter = nullptr;

            checkLoadData();
        }
    } else {
        if (cryptKey && !cryptKey->empty()) {
            KFKVInfo("setting new aes key");
            auto ptr = cryptKey->data();
            m_crypter = new AESCrypt(ptr, cryptKey->length(), nullptr, 0, aes256);

            checkLoadData();
        } else {
            // nothing to do
        }
    }
}

#endif // KFKV_DISABLE_CRYPT

bool KFKV::isFileValid() {
    return m_file->isFileValid();
}

// crc

// assuming m_file is valid
bool KFKV::checkFileCRCValid(size_t actualSize, uint32_t crcDigest) {
    auto ptr = (uint8_t *) m_file->getMemory();
    if (ptr) {
        m_crcDigest = (uint32_t) CRC32(0, (const uint8_t *) ptr + Fixed32Size, (uint32_t) actualSize);

        if (m_crcDigest == crcDigest) {
            return true;
        }
        KFKVError("check crc [%s] fail, crc32:%u, m_crcDigest:%u", m_mmapID.c_str(), crcDigest, m_crcDigest);
    }
    return false;
}

void KFKV::recalculateCRCDigestWithIV(const void *iv) {
    auto ptr = (const uint8_t *) m_file->getMemory();
    if (ptr) {
        m_crcDigest = 0;
        m_crcDigest = (uint32_t) CRC32(0, ptr + Fixed32Size, (uint32_t) m_actualSize);
        writeActualSize(m_actualSize, m_crcDigest, iv, IncreaseSequence);
    }
}

void KFKV::recalculateCRCDigestOnly() {
    auto ptr = (const uint8_t *) m_file->getMemory();
    if (ptr) {
        m_crcDigest = 0;
        m_crcDigest = (uint32_t) CRC32(0, ptr + Fixed32Size, (uint32_t) m_actualSize);
        writeActualSize(m_actualSize, m_crcDigest, nullptr, KeepSequence);
    }
}

void KFKV::updateCRCDigest(const uint8_t *ptr, size_t length) {
    if (ptr == nullptr) {
        return;
    }
    m_crcDigest = (uint32_t) CRC32(m_crcDigest, ptr, (uint32_t) length);

    writeActualSize(m_actualSize, m_crcDigest, nullptr, KeepSequence);
}

// set & get

bool KFKV::set(bool value, KFKVKey_t key) {
    return set(value, key, m_expiredInSeconds);
}

bool KFKV::set(bool value, KFKVKey_t key, uint32_t expireDuration) {
    if (isKeyEmpty(key)) {
        return false;
    }
    size_t size = kfkv_unlikely(m_enableKeyExpire) ? Fixed32Size + pbBoolSize() : pbBoolSize();
    KFKVBuffer data(size);
    CodedOutputData output(data.getPtr(), size);
    output.writeBool(value);
    if (kfkv_unlikely(m_enableKeyExpire)) {
        auto time = (expireDuration != ExpireNever) ? getCurrentTimeInSecond() + expireDuration : ExpireNever;
        output.writeRawLittleEndian32(UInt32ToInt32(time));
    } else {
        assert(expireDuration == ExpireNever && "setting expire duration without calling enableAutoKeyExpire() first");
    }

    return setDataForKey(std::move(data), key);
}

bool KFKV::set(int32_t value, KFKVKey_t key) {
    return set(value, key, m_expiredInSeconds);
}

bool KFKV::set(int32_t value, KFKVKey_t key, uint32_t expireDuration) {
    if (isKeyEmpty(key)) {
        return false;
    }
    size_t size = kfkv_unlikely(m_enableKeyExpire) ? Fixed32Size + pbInt32Size(value) : pbInt32Size(value);
    KFKVBuffer data(size);
    CodedOutputData output(data.getPtr(), size);
    output.writeInt32(value);
    if (kfkv_unlikely(m_enableKeyExpire)) {
        auto time = (expireDuration != ExpireNever) ? getCurrentTimeInSecond() + expireDuration : ExpireNever;
        output.writeRawLittleEndian32(UInt32ToInt32(time));
    } else {
        assert(expireDuration == ExpireNever && "setting expire duration without calling enableAutoKeyExpire() first");
    }

    return setDataForKey(std::move(data), key);
}

bool KFKV::set(uint32_t value, KFKVKey_t key) {
    return set(value, key, m_expiredInSeconds);
}

bool KFKV::set(uint32_t value, KFKVKey_t key, uint32_t expireDuration) {
    if (isKeyEmpty(key)) {
        return false;
    }
    size_t size = kfkv_unlikely(m_enableKeyExpire) ? Fixed32Size + pbUInt32Size(value) : pbUInt32Size(value);
    KFKVBuffer data(size);
    CodedOutputData output(data.getPtr(), size);
    output.writeUInt32(value);
    if (kfkv_unlikely(m_enableKeyExpire)) {
        auto time = (expireDuration != ExpireNever) ? getCurrentTimeInSecond() + expireDuration : ExpireNever;
        output.writeRawLittleEndian32(UInt32ToInt32(time));
    } else {
        assert(expireDuration == ExpireNever && "setting expire duration without calling enableAutoKeyExpire() first");
    }

    return setDataForKey(std::move(data), key);
}

bool KFKV::set(int64_t value, KFKVKey_t key) {
    return set(value, key, m_expiredInSeconds);
}

bool KFKV::set(int64_t value, KFKVKey_t key, uint32_t expireDuration) {
    if (isKeyEmpty(key)) {
        return false;
    }
    size_t size = kfkv_unlikely(m_enableKeyExpire) ? Fixed32Size + pbInt64Size(value) : pbInt64Size(value);
    KFKVBuffer data(size);
    CodedOutputData output(data.getPtr(), size);
    output.writeInt64(value);
    if (kfkv_unlikely(m_enableKeyExpire)) {
        auto time = (expireDuration != ExpireNever) ? getCurrentTimeInSecond() + expireDuration : ExpireNever;
        output.writeRawLittleEndian32(UInt32ToInt32(time));
    } else {
        assert(expireDuration == ExpireNever && "setting expire duration without calling enableAutoKeyExpire() first");
    }

    return setDataForKey(std::move(data), key);
}

bool KFKV::set(uint64_t value, KFKVKey_t key) {
    return set(value, key, m_expiredInSeconds);
}

bool KFKV::set(uint64_t value, KFKVKey_t key, uint32_t expireDuration) {
    if (isKeyEmpty(key)) {
        return false;
    }
    size_t size = kfkv_unlikely(m_enableKeyExpire) ? Fixed32Size + pbUInt64Size(value) : pbUInt64Size(value);
    KFKVBuffer data(size);
    CodedOutputData output(data.getPtr(), size);
    output.writeUInt64(value);
    if (kfkv_unlikely(m_enableKeyExpire)) {
        auto time = (expireDuration != ExpireNever) ? getCurrentTimeInSecond() + expireDuration : ExpireNever;
        output.writeRawLittleEndian32(UInt32ToInt32(time));
    } else {
        assert(expireDuration == ExpireNever && "setting expire duration without calling enableAutoKeyExpire() first");
    }

    return setDataForKey(std::move(data), key);
}

bool KFKV::set(float value, KFKVKey_t key) {
    return set(value, key, m_expiredInSeconds);
}

bool KFKV::set(float value, KFKVKey_t key, uint32_t expireDuration) {
    if (isKeyEmpty(key)) {
        return false;
    }
    size_t size = kfkv_unlikely(m_enableKeyExpire) ? Fixed32Size + pbFloatSize() : pbFloatSize();
    KFKVBuffer data(size);
    CodedOutputData output(data.getPtr(), size);
    output.writeFloat(value);
    if (kfkv_unlikely(m_enableKeyExpire)) {
        auto time = (expireDuration != ExpireNever) ? getCurrentTimeInSecond() + expireDuration : ExpireNever;
        output.writeRawLittleEndian32(UInt32ToInt32(time));
    } else {
        assert(expireDuration == ExpireNever && "setting expire duration without calling enableAutoKeyExpire() first");
    }

    return setDataForKey(std::move(data), key);
}

bool KFKV::set(double value, KFKVKey_t key) {
    return set(value, key, m_expiredInSeconds);
}

bool KFKV::set(double value, KFKVKey_t key, uint32_t expireDuration) {
    if (isKeyEmpty(key)) {
        return false;
    }
    size_t size = kfkv_unlikely(m_enableKeyExpire) ? Fixed32Size + pbDoubleSize() : pbDoubleSize();
    KFKVBuffer data(size);
    CodedOutputData output(data.getPtr(), size);
    output.writeDouble(value);
    if (kfkv_unlikely(m_enableKeyExpire)) {
        auto time = (expireDuration != ExpireNever) ? getCurrentTimeInSecond() + expireDuration : ExpireNever;
        output.writeRawLittleEndian32(UInt32ToInt32(time));
    } else {
        assert(expireDuration == ExpireNever && "setting expire duration without calling enableAutoKeyExpire() first");
    }

    return setDataForKey(std::move(data), key);
}

bool KFKV::setDataForKey(kfkv::KFKVBuffer &&data, KFKV::KFKVKey_t key, uint32_t expireDuration) {
    if (kfkv_likely(!m_enableKeyExpire)) {
        assert(expireDuration == ExpireNever && "setting expire duration without calling enableAutoKeyExpire() first");
        return setDataForKey(std::move(data), key, true);
    } else {
        auto tmp = KFKVBuffer(pbKFKVBufferSize(data) + Fixed32Size);
        CodedOutputData output(tmp.getPtr(), tmp.length());
        output.writeData(data);
        auto time = (expireDuration != ExpireNever) ? getCurrentTimeInSecond() + expireDuration : ExpireNever;
        output.writeRawLittleEndian32(UInt32ToInt32(time));
        return setDataForKey(std::move(tmp), key);
    }
}

bool KFKV::set(const char *value, KFKVKey_t key) {
    return set(value, key, m_expiredInSeconds);
}

bool KFKV::set(const char *value, KFKVKey_t key, uint32_t expireDuration) {
    if (!value) {
        removeValueForKey(key);
        return true;
    }
    return setDataForKey(KFKVBuffer((void *) value, strlen(value), KFKVBufferNoCopy), key, expireDuration);
}

bool KFKV::set(const string &value, KFKVKey_t key) {
    return set(value, key, m_expiredInSeconds);
}

bool KFKV::set(const string &value, KFKVKey_t key, uint32_t expireDuration) {
    if (isKeyEmpty(key)) {
        return false;
    }
    return setDataForKey(KFKVBuffer((void *) value.data(), value.length(), KFKVBufferNoCopy), key, expireDuration);
}

bool KFKV::set(string_view value, KFKVKey_t key) {
    return set(value, key, m_expiredInSeconds);
}

bool KFKV::set(string_view value, KFKVKey_t key, uint32_t expireDuration) {
    if (isKeyEmpty(key)) {
        return false;
    }
    return setDataForKey(KFKVBuffer((void *) value.data(), value.length(), KFKVBufferNoCopy), key, expireDuration);
}

bool KFKV::set(const KFKVBuffer &value, KFKVKey_t key) {
    return set(value, key, m_expiredInSeconds);
}

bool KFKV::set(const KFKVBuffer &value, KFKVKey_t key, uint32_t expireDuration) {
    if (isKeyEmpty(key)) {
        return false;
    }
    return setDataForKey(KFKVBuffer(value.getPtr(), value.length(), KFKVBufferNoCopy), key, expireDuration);
}

bool KFKV::set(const vector<string> &value, KFKVKey_t key) {
    return set(value, key, m_expiredInSeconds);
}

bool KFKV::set(const vector<string> &v, KFKVKey_t key, uint32_t expireDuration) {
    if (isKeyEmpty(key)) {
        return false;
    }
#ifdef KFKV_HAS_CPP20
    auto data = MiniPBCoder::encodeDataWithObject(std::span(v));
#else
    auto data = MiniPBCoder::encodeDataWithObject(v);
#endif
    if (kfkv_unlikely(m_enableKeyExpire) && data.length() > 0) {
        auto tmp = KFKVBuffer(data.length() + Fixed32Size);
        auto ptr = (uint8_t *) tmp.getPtr();
        memcpy(ptr, data.getPtr(), data.length());
        auto time = (expireDuration != ExpireNever) ? getCurrentTimeInSecond() + expireDuration : ExpireNever;
        memcpy(ptr + data.length(), &time, Fixed32Size);
        data = std::move(tmp);
    }
    return setDataForKey(std::move(data), key);
}

bool KFKV::getString(KFKVKey_t key, string &result, bool inplaceModification) {
    if (isKeyEmpty(key)) {
        return false;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    auto data = getDataForKey(key);
    if (data.length() > 0) {
        try {
            CodedInputData input(data.getPtr(), data.length());
            if (inplaceModification) {
                input.readString(result);
            } else {
                result = input.readString();
            }
            return true;
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("decode fail");
        }
    }
    return false;
}

bool KFKV::getBytes(KFKVKey_t key, kfkv::KFKVBuffer &result) {
    if (isKeyEmpty(key)) {
        return false;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    auto data = getDataForKey(key);
    if (data.length() > 0) {
        try {
            CodedInputData input(data.getPtr(), data.length());
            result = input.readData();
            return true;
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("decode fail");
        }
    }
    return false;
}

KFKVBuffer KFKV::getBytes(KFKVKey_t key) {
    if (isKeyEmpty(key)) {
        return KFKVBuffer();
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    auto data = getDataForKey(key);
    if (data.length() > 0) {
        try {
            CodedInputData input(data.getPtr(), data.length());
            return input.readData();
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("decode fail");
        }
    }
    return KFKVBuffer();
}

bool KFKV::getVector(KFKVKey_t key, vector<string> &result) {
    if (isKeyEmpty(key)) {
        return false;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    auto data = getDataForKey(key);
    if (data.length() > 0) {
        try {
            result = MiniPBCoder::decodeVector(data);
            return true;
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("decode fail");
        }
    }
    return false;
}

void KFKV::shared_lock() {
    m_lock->lock();
    m_sharedProcessLock->lock();
}

void KFKV::shared_unlock() {
    m_sharedProcessLock->unlock();
    m_lock->unlock();
}

bool KFKV::getBool(KFKVKey_t key, bool defaultValue, bool *hasValue) {
    if (isKeyEmpty(key)) {
        if (hasValue != nullptr) {
            *hasValue = false;
        }
        return defaultValue;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    auto data = getDataForKey(key);
    if (data.length() > 0) {
        try {
            CodedInputData input(data.getPtr(), data.length());
            if (hasValue != nullptr) {
                *hasValue = true;
            }
            return input.readBool();
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("decode fail");
        }
    }
    if (hasValue != nullptr) {
        *hasValue = false;
    }
    return defaultValue;
}

int32_t KFKV::getInt32(KFKVKey_t key, int32_t defaultValue, bool *hasValue) {
    if (isKeyEmpty(key)) {
        if (hasValue != nullptr) {
            *hasValue = false;
        }
        return defaultValue;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    auto data = getDataForKey(key);
    if (data.length() > 0) {
        try {
            CodedInputData input(data.getPtr(), data.length());
            if (hasValue != nullptr) {
                *hasValue = true;
            }
            return input.readInt32();
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("decode fail");
        }
    }
    if (hasValue != nullptr) {
        *hasValue = false;
    }
    return defaultValue;
}

uint32_t KFKV::getUInt32(KFKVKey_t key, uint32_t defaultValue, bool *hasValue) {
    if (isKeyEmpty(key)) {
        if (hasValue != nullptr) {
            *hasValue = false;
        }
        return defaultValue;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    auto data = getDataForKey(key);
    if (data.length() > 0) {
        try {
            CodedInputData input(data.getPtr(), data.length());
            if (hasValue != nullptr) {
                *hasValue = true;
            }
            return input.readUInt32();
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("decode fail");
        }
    }
    if (hasValue != nullptr) {
        *hasValue = false;
    }
    return defaultValue;
}

int64_t KFKV::getInt64(KFKVKey_t key, int64_t defaultValue, bool *hasValue) {
    if (isKeyEmpty(key)) {
        if (hasValue != nullptr) {
            *hasValue = false;
        }
        return defaultValue;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    auto data = getDataForKey(key);
    if (data.length() > 0) {
        try {
            CodedInputData input(data.getPtr(), data.length());
            if (hasValue != nullptr) {
                *hasValue = true;
            }
            return input.readInt64();
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("decode fail");
        }
    }
    if (hasValue != nullptr) {
        *hasValue = false;
    }
    return defaultValue;
}

uint64_t KFKV::getUInt64(KFKVKey_t key, uint64_t defaultValue, bool *hasValue) {
    if (isKeyEmpty(key)) {
        if (hasValue != nullptr) {
            *hasValue = false;
        }
        return defaultValue;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    auto data = getDataForKey(key);
    if (data.length() > 0) {
        try {
            CodedInputData input(data.getPtr(), data.length());
            if (hasValue != nullptr) {
                *hasValue = true;
            }
            return input.readUInt64();
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("decode fail");
        }
    }
    if (hasValue != nullptr) {
        *hasValue = false;
    }
    return defaultValue;
}

float KFKV::getFloat(KFKVKey_t key, float defaultValue, bool *hasValue) {
    if (isKeyEmpty(key)) {
        if (hasValue != nullptr) {
            *hasValue = false;
        }
        return defaultValue;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    auto data = getDataForKey(key);
    if (data.length() > 0) {
        try {
            CodedInputData input(data.getPtr(), data.length());
            if (hasValue != nullptr) {
                *hasValue = true;
            }
            return input.readFloat();
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("decode fail");
        }
    }
    if (hasValue != nullptr) {
        *hasValue = false;
    }
    return defaultValue;
}

double KFKV::getDouble(KFKVKey_t key, double defaultValue, bool *hasValue) {
    if (isKeyEmpty(key)) {
        if (hasValue != nullptr) {
            *hasValue = false;
        }
        return defaultValue;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    auto data = getDataForKey(key);
    if (data.length() > 0) {
        try {
            CodedInputData input(data.getPtr(), data.length());
            if (hasValue != nullptr) {
                *hasValue = true;
            }
            return input.readDouble();
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("decode fail");
        }
    }
    if (hasValue != nullptr) {
        *hasValue = false;
    }
    return defaultValue;
}

size_t KFKV::getValueSize(KFKVKey_t key, bool actualSize) {
    if (isKeyEmpty(key)) {
        return 0;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    auto data = getDataForKey(key);
    if (actualSize) {
        try {
            CodedInputData input(data.getPtr(), data.length());
            auto length = input.readInt32();
            if (length >= 0) {
                auto s_length = static_cast<size_t>(length);
                if (pbRawVarint32Size(length) + s_length == data.length()) {
                    return s_length;
                }
            }
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("decode fail");
        }
    }
    return data.length();
}

int32_t KFKV::writeValueToBuffer(KFKVKey_t key, void *ptr, int32_t size) {
    if (isKeyEmpty(key) || size < 0) {
        return -1;
    }
    auto s_size = static_cast<size_t>(size);

    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    auto data = getDataForKey(key);
    try {
        CodedInputData input(data.getPtr(), data.length());
        auto length = input.readInt32();
        auto offset = pbRawVarint32Size(length);
        if (length >= 0) {
            auto s_length = static_cast<size_t>(length);
            if (offset + s_length == data.length()) {
                if (s_length <= s_size) {
                    memcpy(ptr, (uint8_t *) data.getPtr() + offset, s_length);
                    return length;
                }
            } else {
                if (data.length() <= s_size) {
                    memcpy(ptr, data.getPtr(), data.length());
                    return static_cast<int32_t>(data.length());
                }
            }
        }
    } catch (std::exception &exception) {
        KFKVError("%s", exception.what());
    } catch (...) {
        KFKVError("encode fail");
    }
    return -1;
}

// enumerate

bool KFKV::containsKey(KFKVKey_t key) {
    SCOPED_LOCK(m_lock);
    checkLoadData();

    if (kfkv_likely(!m_enableKeyExpire)) {
        if (m_crypter) {
            return m_dicCrypt->find(key) != m_dicCrypt->end();
        } else {
            return m_dic->find(key) != m_dic->end();
        }
    }
    auto raw = getDataWithoutMTimeForKey(key);
    return raw.length() != 0;
}

size_t KFKV::count(bool filterExpire) {
    SCOPED_LOCK(m_lock);
    checkLoadData();

    if (kfkv_unlikely(filterExpire && m_enableKeyExpire)) {
        SCOPED_LOCK(m_exclusiveProcessLock);
        fullWriteback(nullptr, true);
    }

    if (m_crypter) {
        return m_dicCrypt->size();
    } else {
        return m_dic->size();
    }
}

size_t KFKV::totalSize() {
    SCOPED_LOCK(m_lock);
    checkLoadData();
    return m_file->getFileSize();
}

size_t KFKV::actualSize() {
    SCOPED_LOCK(m_lock);
    checkLoadData();
    return m_actualSize;
}

bool KFKV::removeValueForKey(KFKVKey_t key) {
    if (isKeyEmpty(key)) {
        return false;
    }
    if (isReadOnly()) {
        KFKVWarning("[%s] file readonly", m_mmapID.c_str());
        return false;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_exclusiveProcessLock);
    checkLoadData();

    return removeDataForKey(key);
}

#ifndef KFKV_APPLE

vector<string> KFKV::allKeys(bool filterExpire) {
    SCOPED_LOCK(m_lock);
    checkLoadData();

    if (kfkv_unlikely(filterExpire && m_enableKeyExpire)) {
        SCOPED_LOCK(m_exclusiveProcessLock);
        fullWriteback(nullptr, true);
    }

    vector<string> keys;
    if (m_crypter) {
        for (const auto &itr : *m_dicCrypt) {
            keys.push_back(itr.first);
        }
    } else {
        for (const auto &itr : *m_dic) {
            keys.push_back(itr.first);
        }
    }
    return keys;
}

bool KFKV::removeValuesForKeys(const vector<string> &arrKeys) {
    if (isReadOnly()) {
        KFKVWarning("[%s] file readonly", m_mmapID.c_str());
        return false;
    }
    if (arrKeys.empty()) {
        return true;
    }
    if (arrKeys.size() == 1) {
        return removeValueForKey(arrKeys[0]);
    }

    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_exclusiveProcessLock);
    checkLoadData();

    size_t deleteCount = 0;
    if (m_crypter) {
        for (const auto &key : arrKeys) {
            auto itr = m_dicCrypt->find(key);
            if (itr != m_dicCrypt->end()) {
                m_dicCrypt->erase(itr);
                deleteCount++;
            }
        }
    } else {
        for (const auto &key : arrKeys) {
            auto itr = m_dic->find(key);
            if (itr != m_dic->end()) {
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

#endif // KFKV_APPLE

// file

void KFKV::sync(SyncFlag flag) {
    KFKVInfo("KFKV::sync, SyncFlag = %d", flag);
    SCOPED_LOCK(m_lock);
    if (m_needLoadFromFile || !isFileValid()) {
        return;
    }
    SCOPED_LOCK(m_exclusiveProcessLock);

    m_file->msync(flag);
    m_metaFile->msync(flag);
}

void KFKV::lock() {
    SCOPED_LOCK(m_lock);
    m_exclusiveProcessLock->lock();
}
void KFKV::unlock() {
    SCOPED_LOCK(m_lock);
    m_exclusiveProcessLock->unlock();
}
bool KFKV::try_lock() {
    SCOPED_LOCK(m_lock);
    return m_exclusiveProcessLock->try_lock();
}

#ifndef KFKV_WIN32
void KFKV::lock_thread() {
    m_lock->lock();
}
void KFKV::unlock_thread() {
    m_lock->unlock();
}
bool KFKV::try_lock_thread() {
    return m_lock->try_lock();
}
#endif

// backup

static bool backupOneToDirectoryByFilePath(const string &mmapKey, const KFKVPath_t &srcPath, const KFKVPath_t &dstPath) {
    File crcFile(srcPath, OpenFlag::ReadOnly);
    if (!crcFile.isFileValid()) {
        return false;
    }

    bool ret;
    {
        const auto &dstUTF8Path = KFKVPath_t2String(dstPath);
        KFKVInfo("backup one kfkv[%s] from [%s] to [%s]", mmapKey.c_str(), crcFile.getUTF8Path().c_str(),
                 dstUTF8Path.c_str());
        FileLock fileLock(crcFile.getFd());
        InterProcessLock lock(&fileLock, SharedLockType);
        SCOPED_LOCK(&lock);

        ret = copyFile(srcPath, dstPath);
        if (ret) {
            auto srcCRCPath = srcPath + CRC_SUFFIX;
            auto dstCRCPath = dstPath + CRC_SUFFIX;
            ret = copyFile(srcCRCPath, dstCRCPath);
        }
        KFKVInfo("finish backup one kfkv[%s]", mmapKey.c_str());
    }
    return ret;
}

bool KFKV::backupOneToDirectory(const string &mmapKey, const KFKVPath_t &dstPath, const KFKVPath_t &srcPath, bool compareFullPath) {
    if (!g_instanceLock) {
        return false;
    }
    // we have to lock the creation of KFKV instance, regardless of in cache or not
    SCOPED_LOCK(g_instanceLock);
    KFKV *kv = nullptr;
    if (!compareFullPath) {
        auto itr = g_instanceDic->find(mmapKey);
        if (itr != g_instanceDic->end()) {
            kv = itr->second;
        }
    } else {
        // mmapKey is actually filename, we can't simply call find()
        for (auto &pair : *g_instanceDic) {
            if (pair.second->m_path == srcPath) {
                kv = pair.second;
                break;
            }
        }
    }
    // get one in cache, do it the easy way
    if (kv) {
        const auto &srcUTF8Path = KFKVPath_t2String(srcPath);
        const auto &dstUTF8Path = KFKVPath_t2String(dstPath);
        KFKVInfo("backup one cached kfkv[%s] from [%s] to [%s]", mmapKey.c_str(), srcUTF8Path.c_str(),
                 dstUTF8Path.c_str());
        SCOPED_LOCK(kv->m_lock);
        SCOPED_LOCK(kv->m_sharedProcessLock);

        kv->sync();
        auto ret = copyFile(kv->m_path, dstPath);
        if (ret) {
            auto dstCRCPath = dstPath + CRC_SUFFIX;
            ret = copyFile(kv->m_crcPath, dstCRCPath);
        }
        KFKVInfo("finish backup one kfkv[%s], ret: %d", mmapKey.c_str(), ret);
        return ret;
    }

    // no luck with cache, do it the hard way
    bool ret = backupOneToDirectoryByFilePath(mmapKey, srcPath, dstPath);
    return ret;
}

bool KFKV::backupOneToDirectory(const string &mmapID, const KFKVPath_t &dstDir, const KFKVPath_t *srcDir) {
    auto rootPath = srcDir ? srcDir : &g_realRootDir;
    if (*rootPath == dstDir) {
        return true;
    }
    mkPath(dstDir);
    auto dstPath = mappedKVPathWithID(mmapID, &dstDir);
    auto ns = nameSpace(*rootPath);
    rootPath = &ns.getRootDir();
    string  mmapKey = mmapedKVKey(mmapID, rootPath, true);
#ifdef KFKV_ANDROID
    string srcPath;
    switch (tryMigrateLegacyKFKVFile(mmapID, rootPath, true)) {
        case MigrateStatus::OldToNewMigrateFail: {
            auto legacyID = legacyMmapedKVKey(mmapID, rootPath);
            srcPath = mappedKVPathWithID(legacyID, rootPath, KFKV_MULTI_PROCESS, true);
            break;
        }
        case MigrateStatus::NoneExist:
            KFKVWarning("file with ID [%s] not exist in path [%s]", mmapID.c_str(), rootPath->c_str());
            return false;
        default:
            srcPath = mappedKVPathWithID(mmapID, rootPath, KFKV_MULTI_PROCESS, true);
            break;
    }
#else
    auto srcPath = mappedKVPathWithID(mmapID, rootPath, true);
#endif
    return backupOneToDirectory(mmapKey, dstPath, srcPath, false);
}

bool endsWith(const KFKVPath_t &str, const KFKVPath_t &suffix) {
    if (str.length() >= suffix.length()) {
        return str.compare(str.length() - suffix.length(), suffix.length(), suffix) == 0;
    } else {
        return false;
    }
}

KFKVPath_t filename(const KFKVPath_t &path) {
    auto startPos = path.rfind(KFKV_PATH_SLASH);
    startPos++; // don't need to check for npos, because npos+1 == 0
    auto filename = path.substr(startPos);
    return filename;
}

size_t KFKV::backupAllToDirectory(const KFKVPath_t &dstDir, const KFKVPath_t &srcDir, bool isInSpecialDir) {
    unordered_set<KFKVPath_t> mmapIDSet;
    unordered_set<KFKVPath_t> mmapIDCRCSet;
    walkInDir(srcDir, WalkFile, [&](const KFKVPath_t &filePath, WalkType) {
        if (endsWith(filePath, CRC_SUFFIX)) {
            mmapIDCRCSet.insert(filePath);
        } else {
            mmapIDSet.insert(filePath);
        }
    });

    size_t count = 0;
    if (!mmapIDSet.empty()) {
        mkPath(dstDir);
        auto compareFullPath = isInSpecialDir;
        for (auto &srcPath : mmapIDSet) {
            auto srcCRCPath = srcPath + CRC_SUFFIX;
            if (mmapIDCRCSet.find(srcCRCPath) == mmapIDCRCSet.end()) {
                const auto &utf8SrcCRCPath = KFKVPath_t2String(srcCRCPath);
                KFKVWarning("crc not exist [%s]", utf8SrcCRCPath.c_str());
                continue;
            }
            auto basename = filename(srcPath);
            const auto &strBasename = KFKVPath_t2String(basename);
            auto mmapKey = isInSpecialDir ? strBasename : mmapedKVKey(strBasename, &srcDir);
            auto dstPath = dstDir + KFKV_PATH_SLASH;
            dstPath += basename;
            if (backupOneToDirectory(mmapKey, dstPath, srcPath, compareFullPath)) {
                count++;
            }
        }
    }
    return count;
}

size_t KFKV::backupAllToDirectory(const KFKVPath_t &dstDir, const KFKVPath_t *srcDir) {
    auto rootPath = srcDir ? srcDir : &g_realRootDir;
    if (*rootPath == dstDir) {
        return true;
    }
    auto count = backupAllToDirectory(dstDir, *rootPath, false);

    auto specialSrcDir = *rootPath + KFKV_PATH_SLASH + SPECIAL_CHARACTER_DIRECTORY_NAME;
    if (isFileExist(specialSrcDir)) {
        auto specialDstDir = dstDir + KFKV_PATH_SLASH + SPECIAL_CHARACTER_DIRECTORY_NAME;
        count += backupAllToDirectory(specialDstDir, specialSrcDir, true);
    }
    return count;
}

// restore

static bool restoreOneFromDirectoryByFilePath(const string &mmapKey, const KFKVPath_t &srcPath, const KFKVPath_t &dstPath) {
    auto dstCRCPath = dstPath + CRC_SUFFIX;
    File dstCRCFile(std::move(dstCRCPath), OpenFlag::ReadWrite | OpenFlag::Create);
    if (!dstCRCFile.isFileValid()) {
        return false;
    }

    bool ret;
    {
        const auto &srcUTF8Path = KFKVPath_t2String(srcPath);
        const auto &dstUTF8Path = KFKVPath_t2String(dstPath);
        KFKVInfo("restore one kfkv[%s] from [%s] to [%s]", mmapKey.c_str(), srcUTF8Path.c_str(), dstUTF8Path.c_str());
        FileLock fileLock(dstCRCFile.getFd());
        InterProcessLock lock(&fileLock, ExclusiveLockType);
        SCOPED_LOCK(&lock);

        ret = copyFileContent(srcPath, dstPath);
        if (ret) {
            auto srcCRCPath = srcPath + CRC_SUFFIX;
            ret = copyFileContent(srcCRCPath, dstCRCFile.getFd());
        }
        KFKVInfo("finish restore one kfkv[%s]", mmapKey.c_str());
    }
    return ret;
}

// We can't simply replace the existing file, because other processes might have already open it.
// They won't know a difference when the file has been replaced.
// We have to let them know by overriding the existing file with new content.
bool KFKV::restoreOneFromDirectory(const string &mmapKey, const KFKVPath_t &srcPath, const KFKVPath_t &dstPath, bool compareFullPath) {
    if (!g_instanceLock) {
        return false;
    }
    // we have to lock the creation of KFKV instance, regardless of in cache or not
    SCOPED_LOCK(g_instanceLock);
    KFKV *kv = nullptr;
    if (!compareFullPath) {
        auto itr = g_instanceDic->find(mmapKey);
        if (itr != g_instanceDic->end()) {
            kv = itr->second;
        }
    } else {
        // mmapKey is actually filename, we can't simply call find()
        for (auto &pair : *g_instanceDic) {
            if (pair.second->m_path == dstPath) {
                kv = pair.second;
                break;
            }
        }
    }
    // get one in cache, do it the easy way
    if (kv) {
        const auto &srcUTF8Path = KFKVPath_t2String(srcPath);
        const auto &dstUTF8Path = KFKVPath_t2String(dstPath);
        KFKVInfo("restore one cached kfkv[%s] from [%s] to [%s]", mmapKey.c_str(), srcUTF8Path.c_str(),
                 dstUTF8Path.c_str());
        SCOPED_LOCK(kv->m_lock);
        SCOPED_LOCK(kv->m_exclusiveProcessLock);

        kv->sync();
        auto ret = copyFileContent(srcPath, kv->m_file->getFd());
        kv->m_file->cleanMayflyFD();
        if (ret) {
            auto srcCRCPath = srcPath + CRC_SUFFIX;
            // ret = copyFileContent(srcCRCPath, kv->m_metaFile->getFd());
            // kv->m_metaFile->cleanMayflyFD();
#ifndef KFKV_ANDROID
            MemoryFile srcCRCFile(srcCRCPath);
#else
            MemoryFile srcCRCFile(srcCRCPath, MMFILE_TYPE_FILE);
#endif
            if (srcCRCFile.isFileValid()) {
                memcpy(kv->m_metaFile->getMemory(), srcCRCFile.getMemory(), sizeof(KFKVMetaInfo));
            } else {
                ret = false;
            }
        }

        // reload data after restore
        kv->clearMemoryCache();
        kv->loadFromFile();
        if (kv->isMultiProcess()) {
            kv->notifyContentChanged();
        }

        KFKVInfo("finish restore one kfkv[%s], ret: %d", mmapKey.c_str(), ret);
        return ret;
    }

    // no luck with cache, do it the hard way
    bool ret = restoreOneFromDirectoryByFilePath(mmapKey, srcPath, dstPath);
    return ret;
}

bool KFKV::restoreOneFromDirectory(const string &mmapID, const KFKVPath_t &srcDir, const KFKVPath_t *dstDir) {
    auto rootPath = dstDir ? dstDir : &g_realRootDir;
    if (*rootPath == srcDir) {
        return true;
    }
    mkPath(*rootPath);
    auto ns = nameSpace(*rootPath);
    rootPath = &ns.getRootDir();
    auto mmapKey = mmapedKVKey(mmapID, rootPath, true);
#ifdef KFKV_ANDROID
    auto srcPath = mappedKVPathWithID(mmapID, &srcDir, KFKV_MULTI_PROCESS, true);
    string dstPath;
    if (tryMigrateLegacyKFKVFile(mmapID, rootPath, true) == MigrateStatus::OldToNewMigrateFail) {
        auto legacyID = legacyMmapedKVKey(mmapID, rootPath);
        dstPath = mappedKVPathWithID(legacyID, rootPath, KFKV_MULTI_PROCESS, true);
    } else {
        dstPath = mappedKVPathWithID(mmapID, rootPath, KFKV_MULTI_PROCESS, true);
    }
#else
    auto srcPath = mappedKVPathWithID(mmapID, &srcDir, true);
    auto dstPath = mappedKVPathWithID(mmapID, rootPath, true);
#endif
    return restoreOneFromDirectory(mmapKey, srcPath, dstPath, false);
}

size_t KFKV::restoreAllFromDirectory(const KFKVPath_t &srcDir, const KFKVPath_t &dstDir, bool isInSpecialDir) {
    unordered_set<KFKVPath_t> mmapIDSet;
    unordered_set<KFKVPath_t> mmapIDCRCSet;
    walkInDir(srcDir, WalkFile, [&](const KFKVPath_t &filePath, WalkType) {
        if (endsWith(filePath, CRC_SUFFIX)) {
            mmapIDCRCSet.insert(filePath);
        } else {
            mmapIDSet.insert(filePath);
        }
    });

    size_t count = 0;
    if (!mmapIDSet.empty()) {
        mkPath(dstDir);
        auto compareFullPath = isInSpecialDir;
        for (auto &srcPath : mmapIDSet) {
            auto srcCRCPath = srcPath + CRC_SUFFIX;
            if (mmapIDCRCSet.find(srcCRCPath) == mmapIDCRCSet.end()) {
                const auto &utf8SrcCRCPath = KFKVPath_t2String(srcCRCPath);
                KFKVWarning("crc not exist [%s]", utf8SrcCRCPath.c_str());
                continue;
            }
            auto basename = filename(srcPath);
            const auto &strBasename = KFKVPath_t2String(basename);
            auto mmapKey = isInSpecialDir ? strBasename : mmapedKVKey(strBasename, &dstDir);
            auto dstPath = dstDir + KFKV_PATH_SLASH;
            dstPath += basename;
            if (restoreOneFromDirectory(mmapKey, srcPath, dstPath, compareFullPath)) {
                count++;
            }
        }
    }
    return count;
}

size_t KFKV::restoreAllFromDirectory(const KFKVPath_t &srcDir, const KFKVPath_t *dstDir) {
    auto rootPath = dstDir ? dstDir : &g_realRootDir;
    if (*rootPath == srcDir) {
        return true;
    }
    auto count = restoreAllFromDirectory(srcDir, *rootPath, true);

    auto specialSrcDir = srcDir + KFKV_PATH_SLASH + SPECIAL_CHARACTER_DIRECTORY_NAME;
    if (isFileExist(specialSrcDir)) {
        auto specialDstDir = *rootPath + KFKV_PATH_SLASH + SPECIAL_CHARACTER_DIRECTORY_NAME;
        count += restoreAllFromDirectory(specialSrcDir, specialDstDir, false);
    }
    return count;
}

// callbacks

void KFKV::registerHandler(kfkv::KFKVHandler *handler) {
    if (!g_instanceLock) {
        return;
    }
    SCOPED_LOCK(g_instanceLock);
    g_handler = handler;
}

void KFKV::unRegisterHandler() {
    if (!g_instanceLock) {
        return;
    }
    SCOPED_LOCK(g_instanceLock);
    g_handler = nullptr;
}

void KFKV::setLogLevel(KFKVLogLevel level) {
    if (!g_instanceLock) {
        return;
    }
    SCOPED_LOCK(g_instanceLock);
    g_currentLogLevel = level;
}

static void mkSpecialCharacterFileDirectory() {
    KFKVPath_t path = g_realRootDir + KFKV_PATH_SLASH + SPECIAL_CHARACTER_DIRECTORY_NAME;
    mkPath(path);
}

template <typename T>
static string md5(const basic_string<T> &value) {
    uint8_t md[MD5_DIGEST_LENGTH] = {};
    char tmp[3] = {}, buf[33] = {};
    openssl::MD5((const uint8_t *) value.c_str(), value.size() * (sizeof(T) / sizeof(uint8_t)), md);
    for (auto ch : md) {
        snprintf(tmp, sizeof(tmp), "%2.2x", ch);
        strcat(buf, tmp);
    }
    return {buf};
}

static KFKVPath_t encodeFilePath(const string &mmapID) {
    const char *specialCharacters = "\\/:*?\"<>|";
    string encodedID;
    bool hasSpecialCharacter = false;
    for (auto ch : mmapID) {
        if (strchr(specialCharacters, ch) != nullptr) {
            encodedID = md5(mmapID);
            hasSpecialCharacter = true;
            break;
        }
    }
    if (hasSpecialCharacter) {
        static ThreadOnceToken_t once = ThreadOnceUninitialized;
        ThreadLock::ThreadOnce(&once, mkSpecialCharacterFileDirectory);
        return KFKVPath_t(SPECIAL_CHARACTER_DIRECTORY_NAME) + KFKV_PATH_SLASH + string2KFKVPath_t(encodedID);
    } else {
        return string2KFKVPath_t(mmapID);
    }
}

static KFKVPath_t encodeFilePath(const string &mmapID, const KFKVPath_t &rootDir) {
    const char *specialCharacters = "\\/:*?\"<>|";
    string encodedID;
    bool hasSpecialCharacter = false;
    for (auto ch : mmapID) {
        if (strchr(specialCharacters, ch) != nullptr) {
            encodedID = md5(mmapID);
            hasSpecialCharacter = true;
            break;
        }
    }
    if (hasSpecialCharacter) {
        KFKVPath_t path = rootDir + KFKV_PATH_SLASH + SPECIAL_CHARACTER_DIRECTORY_NAME;
        mkPath(path);

        return KFKVPath_t(SPECIAL_CHARACTER_DIRECTORY_NAME) + KFKV_PATH_SLASH + string2KFKVPath_t(encodedID);
    } else {
        return string2KFKVPath_t(mmapID);
    }
}

string mmapedKVKey(const string &mmapID, const KFKVPath_t *rootPath, bool alreadyAbsolute) {
    KFKVPath_t path;
    // compare by pointer to speedup a bit, it's OK false detecting
    if (rootPath && (rootPath != &g_realRootDir)) {
        auto tmp = *rootPath + KFKV_PATH_SLASH + string2KFKVPath_t(mmapID);
        if (alreadyAbsolute) {
            path = std::move(tmp);
        } else {
            path = absolutePath(tmp);
        }
    } else {
        path = g_realRootDir + KFKV_PATH_SLASH + string2KFKVPath_t(mmapID);
    }
    return md5(path);
}

string legacyMmapedKVKey(const string &mmapID, const KFKVPath_t *rootPath) {
    if (rootPath && (*rootPath != g_rootDir)) {
        return md5(*rootPath + KFKV_PATH_SLASH + string2KFKVPath_t(mmapID));
    }
    return mmapID;
}

#ifndef KFKV_ANDROID
KFKVPath_t mappedKVPathWithID(const string &mmapID, const KFKVPath_t *rootPath, bool alreadyAbsolute) {
    if (rootPath && (rootPath != &g_realRootDir)) {
        auto path = *rootPath + KFKV_PATH_SLASH + encodeFilePath(mmapID, *rootPath);
        if (alreadyAbsolute) {
            return path;
        } else {
            return absolutePath(path);
        }
    }
    auto path = g_realRootDir + KFKV_PATH_SLASH + encodeFilePath(mmapID);
    return path;
}
#else
KFKVPath_t mappedKVPathWithID(const string &mmapID, const KFKVPath_t *rootPath, KFKVMode mode, bool alreadyAbsolute) {
    if (mode & KFKV_ASHMEM) {
        return ashmemKFKVPathWithID(encodeFilePath(mmapID));
    } else if (rootPath && (rootPath != &g_realRootDir)) {
        auto path = *rootPath + KFKV_PATH_SLASH + encodeFilePath(mmapID, *rootPath);
        if (alreadyAbsolute) {
            return path;
        } else {
            return absolutePath(path);
        }
    }
    auto path = g_realRootDir + KFKV_PATH_SLASH + encodeFilePath(mmapID);
    return path;
}
#endif

KFKVPath_t crcPathWithPath(const KFKVPath_t &kvPath) {
    return kvPath + CRC_SUFFIX;
}

KFKVRecoverStrategic onKFKVCRCCheckFail(const string &mmapID) {
    if (g_handler) {
        return g_handler->onKFKVCRCCheckFail(mmapID);
    }
    return OnErrorDiscard;
}

KFKVRecoverStrategic onKFKVFileLengthError(const string &mmapID) {
    if (g_handler) {
        return g_handler->onKFKVFileLengthError(mmapID);
    }
    return OnErrorDiscard;
}

// NameSpace

NameSpace KFKV::nameSpace(const KFKVPath_t &rootDir) {
    if (!g_instanceLock) {
        ensureMinimalInitialize();
    }

    static ThreadOnceToken_t once = ThreadOnceUninitialized;
    ThreadLock::ThreadOnce(&once, []{
        g_namespaceLock = new ThreadLock;
        g_namespaceLock->initialize();
    });
    SCOPED_LOCK(g_namespaceLock);

    auto itr = g_realRootMap.find(rootDir);
    if (itr == g_realRootMap.end()) {
        auto realRoot = absolutePath(rootDir);
        if (realRoot.ends_with(KFKV_PATH_SLASH)) {
            realRoot.erase(realRoot.size() - 1);
        }
        itr = g_realRootMap.emplace(rootDir, realRoot).first;
    }
    return NameSpace(itr->second);
}

NameSpace KFKV::defaultNameSpace() {
    if (g_rootDir.empty()) {
        KFKVWarning("KFKV has not been initialized, there's no default NameSpace.");
        return NameSpace(KFKVPath_t());
    }
    return NameSpace(g_realRootDir);
}

KFKV *NameSpace::kfkvWithID(const string &mmapID, KFKVMode mode, const string *cryptKey, size_t expectedCapacity, bool aes256) {
    KFKVConfig config;
    config.mode = mode;
#ifndef KFKV_DISABLE_CRYPT
    config.aes256 = aes256;
    config.cryptKey = cryptKey;
#endif
    config.rootPath = &m_rootDir;
    config.expectedCapacity = expectedCapacity;
    return KFKV::getKFKVWithID(mmapID, config);
}

KFKV *NameSpace::kfkvWithID(const string &mmapID, const KFKVConfig &config) {
    if (!config.rootPath || *config.rootPath != m_rootDir) {
        auto newConfig = config;
        newConfig.rootPath = &m_rootDir;
        return KFKV::getKFKVWithID(mmapID, newConfig);
    }
    return KFKV::getKFKVWithID(mmapID, config);
}

bool NameSpace::backupOneToDirectory(const std::string &mmapID, const KFKVPath_t &dstDir) {
    return KFKV::backupOneToDirectory(mmapID, dstDir, &m_rootDir);
}

bool NameSpace::restoreOneFromDirectory(const std::string &mmapID, const KFKVPath_t &srcDir) {
    return KFKV::restoreOneFromDirectory(mmapID, srcDir, &m_rootDir);
}

size_t NameSpace::backupAllToDirectory(const KFKVPath_t &dstDir) {
    return KFKV::backupAllToDirectory(dstDir, &m_rootDir);
}

size_t NameSpace::restoreAllFromDirectory(const KFKVPath_t &srcDir) {
    return KFKV::restoreAllFromDirectory(srcDir, &m_rootDir);
}

bool NameSpace::isFileValid(const std::string &mmapID) {
    return KFKV::isFileValid(mmapID, &m_rootDir);
}

bool NameSpace::removeStorage(const std::string &mmapID) {
    return KFKV::removeStorage(mmapID, &m_rootDir);
}

bool NameSpace::checkExist(const std::string &mmapID) {
    return KFKV::checkExist(mmapID, &m_rootDir);
}

KFKV_NAMESPACE_END
