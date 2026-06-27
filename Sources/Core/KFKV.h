
#ifndef KFKV_KFKV_H
#define KFKV_KFKV_H
#ifdef __cplusplus
#include "KFKVPredef.h"

#ifdef KFKV_APPLE

#  include "KFKVBuffer.h"
#  ifdef KFKV_HAS_CPP20
#    include <span>
#  endif

#endif

#include "MiniPBCoder.h"
#include "KFKVHandler.h"

#include <cstdint>
#include <type_traits>
#include <cstring>
#include <optional>

namespace kfkv {
class CodedOutputData;
class MemoryFile;
class AESCrypt;
struct KFKVMetaInfo;
class FileLock;
class InterProcessLock;
class ThreadLock;
class NameSpace;
} // namespace kfkv

KFKV_NAMESPACE_BEGIN

enum KFKVMode : uint32_t {
    KFKV_SINGLE_PROCESS = 1 << 0,
    KFKV_MULTI_PROCESS = 1 << 1,
#ifdef KFKV_ANDROID
    CONTEXT_MODE_MULTI_PROCESS = 1 << 2, // in case someone mistakenly pass Context.MODE_MULTI_PROCESS
    KFKV_ASHMEM = 1 << 3,
    KFKV_BACKUP = 1 << 4,
#endif
    KFKV_READ_ONLY = 1 << 5,
};

static inline KFKVMode operator | (KFKVMode one, KFKVMode other) {
    return static_cast<KFKVMode>(static_cast<uint32_t>(one) | static_cast<uint32_t>(other));
}

// all-in-one configuration for creating KFKV instance
struct KFKVConfig {
    KFKVMode mode = KFKV_SINGLE_PROCESS;

#ifndef KFKV_DISABLE_CRYPT
    bool aes256 = false; // using AES-256 key length
    const std::string *cryptKey = nullptr;
#endif

    const KFKVPath_t *rootPath = nullptr;

    size_t expectedCapacity = 0; // the initial file size

    std::optional<bool> enableKeyExpire = std::nullopt;
    uint32_t expiredInSeconds = 0; // ExpireNever = 0

    bool enableCompareBeforeSet = false;

    std::optional<KFKVRecoverStrategic> recover = std::nullopt; // if not set, use the old style callback
    uint32_t itemSizeLimit = 0; // the size limit of a key-value pair, reject insert if pass limit
};

#define KFKV_OUT

#ifdef KFKV_HAS_CPP20
template <class T>
struct kfkv_is_vector { static constexpr bool value = false; };
template <class T, class A>
struct kfkv_is_vector<std::vector<T, A>> { static constexpr bool value = true; };
template <class T, size_t S>
struct kfkv_is_vector<std::span<T, S>> { static constexpr bool value = true; };
template <class T>
inline constexpr bool kfkv_is_vector_v = kfkv_is_vector<T>::value;

template <class T>
concept KFKV_SUPPORTED_PRIMITIVE_VALUE_TYPE = std::is_integral_v<T> || std::is_floating_point_v<T>;

template <class T>
concept KFKV_SUPPORTED_POD_VALUE_TYPE = std::is_same_v<T, const char*> || std::is_same_v<T, std::string> ||
    std::is_same_v<T, kfkv::KFKVBuffer>;

template <class T>
concept KFKV_SUPPORTED_VECTOR_VALUE_TYPE = kfkv_is_vector_v<T> &&
    (KFKV_SUPPORTED_PRIMITIVE_VALUE_TYPE<typename T::value_type> || KFKV_SUPPORTED_POD_VALUE_TYPE<typename T::value_type>);

template <class T>
concept KFKV_SUPPORTED_VALUE_TYPE = KFKV_SUPPORTED_PRIMITIVE_VALUE_TYPE<T> || KFKV_SUPPORTED_POD_VALUE_TYPE<T> ||
    KFKV_SUPPORTED_VECTOR_VALUE_TYPE<T>;
#endif // KFKV_HAS_CPP20

class KFKV_EXPORT KFKV {
    KFKV(const std::string &mmapID, const KFKVConfig &config);
#ifdef KFKV_ANDROID
#ifndef KFKV_OHOS
    kfkv::FileLock *m_fileModeLock;
    kfkv::InterProcessLock *m_sharedProcessModeLock;
    kfkv::InterProcessLock *m_exclusiveProcessModeLock;
#endif // !KFKV_OHOS
    kfkv::FileLock *m_fileMigrationLock;
    kfkv::InterProcessLock *m_sharedMigrationLock;

    KFKV(const std::string &mmapID, int ashmemFD, int ashmemMetaFd, const KFKVConfig &config);
#endif // KFKV_ANDROID

    ~KFKV();

    std::string m_mmapKey;
    std::string m_mmapID;
    const KFKVMode m_mode;
    KFKVPath_t m_path;
    KFKVPath_t m_crcPath;
    kfkv::KFKVMap *m_dic;
    kfkv::KFKVMapCrypt *m_dicCrypt;

    size_t m_expectedCapacity;

    kfkv::MemoryFile *m_file;
    size_t m_actualSize;
    kfkv::CodedOutputData *m_output;

    bool m_needLoadFromFile;
    bool m_hasFullWriteback;

    uint32_t m_crcDigest;
    kfkv::MemoryFile *m_metaFile;
    kfkv::KFKVMetaInfo *m_metaInfo;

    kfkv::AESCrypt *m_crypter;

    kfkv::ThreadLock *m_lock;
    kfkv::FileLock *m_fileLock;
    kfkv::InterProcessLock *m_sharedProcessLock;
    kfkv::InterProcessLock *m_exclusiveProcessLock;

    bool m_enableKeyExpire = false;
    uint32_t m_expiredInSeconds = ExpireNever;

    bool m_enableCompareBeforeSet = false;

    std::optional<KFKVRecoverStrategic> m_recoverStrategic = std::nullopt;

    uint32_t m_itemSizeLimit = 0;

#ifdef KFKV_APPLE
#ifdef __OBJC__
    using KFKVKey_t = NSString *__unsafe_unretained;
    static bool isKeyEmpty(KFKVKey_t key) { return key.length <= 0; }
#  define kfkv_key_length(key) key.length
#  define kfkv_retain_key(key) CFRetain((__bridge CFTypeRef)(key))
#  define kfkv_release_key(key) CFRelease((__bridge CFTypeRef)(key))
#else
    using KFKVKey_t = std::string_view;
    static bool isKeyEmpty(KFKVKey_t key) { return key.empty(); }
#endif // __OBJC__
#else
    using KFKVKey_t = std::string_view;
    static bool isKeyEmpty(KFKVKey_t key) { return key.empty(); }
#  define kfkv_key_length(key) key.length()
#  define kfkv_retain_key(key) ((void) 0)
#  define kfkv_release_key(key) ((void) 0)
#endif // !KFKV_APPLE

    void loadFromFile();

    void partialLoadFromFile();
    
//#if defined(KFKV_APPLE) || defined(KFKV_WIN32)
// the disk corruption detection is tested in iOS/Win32, but not Android
// let's assume what works for iOS also works on Android for they are all POSIX
    bool m_isSecondLoad = false;
    bool checkFileHasDiskError();
//#else
//    bool checkFileHasDiskError() { return false; }
//#endif

    void loadMetaInfoAndCheck();

    void checkDataValid(bool &loadFromFile, bool &needFullWriteback);

    void checkLoadData();

    bool isFileValid();

    bool checkFileCRCValid(size_t actualSize, uint32_t crcDigest);

    void recalculateCRCDigestWithIV(const void *iv);
    void recalculateCRCDigestOnly();

    void updateCRCDigest(const uint8_t *ptr, size_t length);

    size_t readActualSize();

    void oldStyleWriteActualSize(size_t actualSize);

    bool writeActualSize(size_t size, uint32_t crcDigest, const void *iv, bool increaseSequence);

    bool ensureMemorySize(size_t newSize);

    bool expandAndWriteBack(size_t newSize, std::pair<kfkv::KFKVBuffer, size_t> preparedData, bool needSync = true);

    bool fullWriteback(kfkv::AESCrypt *newCrypter = nullptr, bool onlyWhileExpire = false);

    bool doFullWriteBack(std::pair<kfkv::KFKVBuffer, size_t> preparedData, kfkv::AESCrypt *newCrypter, bool needSync = true);

    bool doFullWriteBack(kfkv::KFKVVector &&vec);

    kfkv::KFKVBuffer getRawDataForKey(KFKVKey_t key);

    kfkv::KFKVBuffer getDataForKey(KFKVKey_t key);

    // isDataHolder: avoid memory copying
    bool setDataForKey(kfkv::KFKVBuffer &&data, KFKVKey_t key, bool isDataHolder = false);

    bool setDataForKey(kfkv::KFKVBuffer &&data, KFKVKey_t key, uint32_t expireDuration);

    bool removeDataForKey(KFKVKey_t key);

    using KVHolderRet_t = std::pair<bool, kfkv::KeyValueHolder>;
    // isDataHolder: avoid memory copying
    KVHolderRet_t doAppendDataWithKey(const kfkv::KFKVBuffer &data, const kfkv::KFKVBuffer &key, bool isDataHolder, uint32_t keyLength);
    KVHolderRet_t appendDataWithKey(const kfkv::KFKVBuffer &data, KFKVKey_t key, bool isDataHolder = false);
    KVHolderRet_t appendDataWithKey(const kfkv::KFKVBuffer &data, const kfkv::KeyValueHolder &kvHolder, bool isDataHolder = false);

    KVHolderRet_t doOverrideDataWithKey(const kfkv::KFKVBuffer &data, const kfkv::KFKVBuffer &key, bool isDataHolder, uint32_t keyLength);
    KVHolderRet_t overrideDataWithKey(const kfkv::KFKVBuffer &data, const kfkv::KeyValueHolder &kvHolder, bool isDataHolder = false);
    KVHolderRet_t overrideDataWithKey(const kfkv::KFKVBuffer &data, KFKVKey_t key, bool isDataHolder = false);
    bool checkSizeForOverride(size_t size);
#ifdef KFKV_APPLE
#ifdef __OBJC__
    kfkv::KFKVBuffer getDataForKey(std::string_view key);
    bool setDataForKey(kfkv::KFKVBuffer &&data, std::string_view key, bool isDataHolder = false);
#endif
    KVHolderRet_t appendDataWithKey(const kfkv::KFKVBuffer &data,
                                    KFKVKey_t key,
                                    const kfkv::KeyValueHolderCrypt &kvHolder,
                                    bool isDataHolder = false);
    KVHolderRet_t overrideDataWithKey(const kfkv::KFKVBuffer &data,
                                      KFKVKey_t key,
                                      const kfkv::KeyValueHolderCrypt &kvHolder,
                                      bool isDataHolder = false);
#endif

    void notifyContentChanged();
    void notifyContentLoaded();

#if defined(KFKV_ANDROID) && !defined(KFKV_DISABLE_CRYPT)
    void checkReSetCryptKey(int fd, int metaFD, const std::string *cryptKey, bool aes256);
#endif
    static bool backupOneToDirectory(const std::string &mmapKey, const KFKVPath_t &dstPath, const KFKVPath_t &srcPath, bool compareFullPath);
    static size_t backupAllToDirectory(const KFKVPath_t &dstDir, const KFKVPath_t &srcDir, bool isInSpecialDir);
    static bool restoreOneFromDirectory(const std::string &mmapKey, const KFKVPath_t &srcPath, const KFKVPath_t &dstPath, bool compareFullPath);
    static size_t restoreAllFromDirectory(const KFKVPath_t &srcDir, const KFKVPath_t &dstDir, bool isInSpecialDir);

    static uint32_t getCurrentTimeInSecond();
    uint32_t getExpireTimeForKey(KFKVKey_t key);
    kfkv::KFKVBuffer getDataWithoutMTimeForKey(KFKVKey_t key);
    size_t filterExpiredKeys();

    static constexpr uint32_t ConstFixed32Size = 4;
    void shared_lock();
    void shared_unlock();

    // assuming rootPath is absolute
    static KFKV *getKFKVWithID(const std::string &mmapID, const KFKVConfig &config);

    void configAutoExipreIfNeeded(const KFKVConfig &config);

    bool checkSizeLimit(size_t size, const kfkv::KFKVBuffer &keyData, uint32_t originKeyLength);

public:
    // call this before getting any KFKV instance
    static void initializeKFKV(const KFKVPath_t &rootDir, KFKVLogLevel logLevel = KFKVLogInfo, kfkv::KFKVHandler *handler = nullptr);

    // a generic purpose instance
    static KFKV *defaultKFKV(KFKVMode mode = KFKV_SINGLE_PROCESS, const std::string *cryptKey = nullptr, bool aes256 = false);
    static KFKV *defaultKFKV(const KFKVConfig &config);

    // mmapID: any unique ID (com.tencent.xin.pay, etc.)
    // if you want a per-user kfkv, you could merge user-id within mmapID
    static KFKV *kfkvWithID(const std::string &mmapID, const KFKVConfig &config);

    // mmapID: any unique ID (com.tencent.xin.pay, etc.)
    // if you want a per-user kfkv, you could merge user-id within mmapID
    // cryptKey: 16 bytes at most
    static KFKV *kfkvWithID(const std::string &mmapID,
                            KFKVMode mode = KFKV_SINGLE_PROCESS,
                            const std::string *cryptKey = nullptr,
                            const KFKVPath_t *rootPath = nullptr,
                            size_t expectedCapacity = 0,
                            bool aes256 = false);

#ifdef KFKV_ANDROID
    static KFKV *kfkvWithAshmemFD(const std::string &mmapID, int fd, int metaFD, const KFKVConfig &config);

    static KFKV *kfkvWithAshmemFD(const std::string &mmapID, int fd, int metaFD, const std::string *cryptKey = nullptr,
                                  bool aes256 = false);

    int ashmemFD();

    int ashmemMetaFD();
#ifndef KFKV_OHOS
    bool checkProcessMode();
    static void enableDisableProcessMode(bool enable);
#endif // !KFKV_OHOS
#endif // KFKV_ANDROID

    // get a namespace with custom root dir
    static kfkv::NameSpace nameSpace(const KFKVPath_t &rootDir);

    // identical with the original KFKV with the global root dir
    static kfkv::NameSpace defaultNameSpace();

    // you can call this on application termination, it's totally fine if you don't call
    static void onExit();

    const std::string &mmapID() const;
#ifndef KFKV_ANDROID
    bool isMultiProcess() const { return  (m_mode & KFKV_MULTI_PROCESS) != 0; }
#else
    bool isMultiProcess() const {
        return (m_mode & KFKV_MULTI_PROCESS) != 0
            || (m_mode & CONTEXT_MODE_MULTI_PROCESS) != 0
            || (m_mode & KFKV_ASHMEM) != 0; // ashmem is always multi-process
    }

    bool isAshmem() const {
        return (m_mode & KFKV_ASHMEM) != 0;
    }
#endif
    bool isReadOnly() const { return (m_mode & KFKV_READ_ONLY) != 0; }

#ifndef KFKV_DISABLE_CRYPT
    std::string cryptKey() const;

    // transform plain text into encrypted text, or vice versa with empty cryptKey
    // you can change existing crypt key with different cryptKey
    bool reKey(const std::string &cryptKey, bool aes256 = false);

    // just reset cryptKey (will not encrypt or decrypt anything)
    // usually you should call this method after other process reKey() the multi-process kfkv
    void checkReSetCryptKey(const std::string *cryptKey, bool aes256 = false);
#endif

    bool set(bool value, KFKVKey_t key);
    bool set(bool value, KFKVKey_t key, uint32_t expireDuration);

    bool set(int32_t value, KFKVKey_t key);
    bool set(int32_t value, KFKVKey_t key, uint32_t expireDuration);

    bool set(uint32_t value, KFKVKey_t key);
    bool set(uint32_t value, KFKVKey_t key, uint32_t expireDuration);

    bool set(int64_t value, KFKVKey_t key);
    bool set(int64_t value, KFKVKey_t key, uint32_t expireDuration);

    bool set(uint64_t value, KFKVKey_t key);
    bool set(uint64_t value, KFKVKey_t key, uint32_t expireDuration);

    bool set(float value, KFKVKey_t key);
    bool set(float value, KFKVKey_t key, uint32_t expireDuration);

    bool set(double value, KFKVKey_t key);
    bool set(double value, KFKVKey_t key, uint32_t expireDuration);

#ifdef KFKV_HAS_CPP20
    // avoid unexpected type conversion (pointer to bool, etc.)
    template <typename T>
    requires(!KFKV_SUPPORTED_VALUE_TYPE<T>)
    bool set(T value, KFKVKey_t key) = delete;

    // avoid unexpected type conversion (pointer to bool, etc.)
    template <typename T>
    requires(!KFKV_SUPPORTED_VALUE_TYPE<T>)
    bool set(T value, KFKVKey_t key, uint32_t expireDuration) = delete;
#else
    // avoid unexpected type conversion (pointer to bool, etc.)
    template <typename T>
    bool set(T value, KFKVKey_t key, uint32_t expireDuration) = delete;
#endif

#ifdef KFKV_APPLE
#ifdef __OBJC__
    bool set(bool value, std::string_view key);
    bool set(bool value, std::string_view key, uint32_t expireDuration);

    bool set(int32_t value, std::string_view key);
    bool set(int32_t value, std::string_view key, uint32_t expireDuration);

    bool set(uint32_t value, std::string_view key);
    bool set(uint32_t value, std::string_view key, uint32_t expireDuration);

    bool set(int64_t value, std::string_view key);
    bool set(int64_t value, std::string_view key, uint32_t expireDuration);

    bool set(uint64_t value, std::string_view key);
    bool set(uint64_t value, std::string_view key, uint32_t expireDuration);

    bool set(float value, std::string_view key);
    bool set(float value, std::string_view key, uint32_t expireDuration);

    bool set(double value, std::string_view key);
    bool set(double value, std::string_view key, uint32_t expireDuration);

    bool set(const char *value, std::string_view key);
    bool set(const char *value, std::string_view key, uint32_t expireDuration);

    bool set(const std::string &value, std::string_view key);
    bool set(const std::string &value, std::string_view key, uint32_t expireDuration);

    bool set(std::string_view value, std::string_view key);
    bool set(std::string_view value, std::string_view key, uint32_t expireDuration);

    bool set(const kfkv::KFKVBuffer &value, std::string_view key);
    bool set(const kfkv::KFKVBuffer &value, std::string_view key, uint32_t expireDuration);

    bool set(const std::vector<std::string> &vector, std::string_view key);
    bool set(const std::vector<std::string> &vector, std::string_view key, uint32_t expireDuration);

    bool containsKey(std::string_view key);

    bool removeValueForKey(std::string_view key);

    bool getBool(std::string_view key, bool defaultValue = false, KFKV_OUT bool *hasValue = nullptr);

    int32_t getInt32(std::string_view key, int32_t defaultValue = 0, KFKV_OUT bool *hasValue = nullptr);

    uint32_t getUInt32(std::string_view key, uint32_t defaultValue = 0, KFKV_OUT bool *hasValue = nullptr);

    int64_t getInt64(std::string_view key, int64_t defaultValue = 0, KFKV_OUT bool *hasValue = nullptr);

    uint64_t getUInt64(std::string_view key, uint64_t defaultValue = 0, KFKV_OUT bool *hasValue = nullptr);

    float getFloat(std::string_view key, float defaultValue = 0, KFKV_OUT bool *hasValue = nullptr);

    double getDouble(std::string_view key, double defaultValue = 0, KFKV_OUT bool *hasValue = nullptr);

    bool getString(std::string_view key, std::string &result, bool inplaceModification = true);

    kfkv::KFKVBuffer getBytes(std::string_view key);

    bool getBytes(std::string_view key, kfkv::KFKVBuffer &result);

#ifdef KFKV_HAS_CPP20
    template<KFKV_SUPPORTED_VECTOR_VALUE_TYPE T>
    bool getVector(std::string_view key, T &result);

    bool getVector(std::string_view key, std::vector<std::string> &result);
#endif

    bool set(NSObject<NSCoding> *__unsafe_unretained obj, KFKVKey_t key);
    bool set(NSObject<NSCoding> *__unsafe_unretained obj, KFKVKey_t key, uint32_t expireDuration);

    NSObject *getObject(KFKVKey_t key, Class cls);
#endif // __OBJC__
#endif  // KFKV_APPLE
    bool set(const char *value, KFKVKey_t key);
    bool set(const char *value, KFKVKey_t key, uint32_t expireDuration);

    bool set(const std::string &value, KFKVKey_t key);
    bool set(const std::string &value, KFKVKey_t key, uint32_t expireDuration);

    bool set(std::string_view value, KFKVKey_t key);
    bool set(std::string_view value, KFKVKey_t key, uint32_t expireDuration);

    bool set(const kfkv::KFKVBuffer &value, KFKVKey_t key);
    bool set(const kfkv::KFKVBuffer &value, KFKVKey_t key, uint32_t expireDuration);

    bool set(const std::vector<std::string> &vector, KFKVKey_t key);
    bool set(const std::vector<std::string> &vector, KFKVKey_t key, uint32_t expireDuration);

#ifdef KFKV_HAS_CPP20
    template<KFKV_SUPPORTED_VECTOR_VALUE_TYPE T>
    bool set(const T& value, KFKVKey_t key) {
        return set<T>(value, key, m_expiredInSeconds);
    }

    template<KFKV_SUPPORTED_VECTOR_VALUE_TYPE T>
    bool set(const T& value, KFKVKey_t key, uint32_t expireDuration);

    template<KFKV_SUPPORTED_VECTOR_VALUE_TYPE T>
    bool getVector(KFKVKey_t key, T &result);
#endif // KFKV_HAS_CPP20

    // inplaceModification is recommended for faster speed
    bool getString(KFKVKey_t key, std::string &result, bool inplaceModification = true);

    kfkv::KFKVBuffer getBytes(KFKVKey_t key);

    bool getBytes(KFKVKey_t key, kfkv::KFKVBuffer &result);

    bool getVector(KFKVKey_t key, std::vector<std::string> &result);

    bool getBool(KFKVKey_t key, bool defaultValue = false, KFKV_OUT bool *hasValue = nullptr);

    int32_t getInt32(KFKVKey_t key, int32_t defaultValue = 0, KFKV_OUT bool *hasValue = nullptr);

    uint32_t getUInt32(KFKVKey_t key, uint32_t defaultValue = 0, KFKV_OUT bool *hasValue = nullptr);

    int64_t getInt64(KFKVKey_t key, int64_t defaultValue = 0, KFKV_OUT bool *hasValue = nullptr);

    uint64_t getUInt64(KFKVKey_t key, uint64_t defaultValue = 0, KFKV_OUT bool *hasValue = nullptr);

    float getFloat(KFKVKey_t key, float defaultValue = 0, KFKV_OUT bool *hasValue = nullptr);

    double getDouble(KFKVKey_t key, double defaultValue = 0, KFKV_OUT bool *hasValue = nullptr);

    // return the actual size consumption of the key's value
    // pass actualSize = true to get value's length
    size_t getValueSize(KFKVKey_t key, bool actualSize);

    // return size written into buffer
    // return -1 on any error
    int32_t writeValueToBuffer(KFKVKey_t key, void *ptr, int32_t size);

    bool containsKey(KFKVKey_t key);

    // filterExpire: return count of all non-expired keys, keep in mind it comes with cost
    size_t count(bool filterExpire = false);

    size_t totalSize();

    size_t actualSize();

    static constexpr uint32_t ExpireNever = 0;

    // all keys created (or last modified) longer than expiredInSeconds will be deleted on next full-write-back
    // expiredInSeconds = KFKV::ExpireNever (0) means no common expiration duration for all keys, aka each key will have it's own expiration duration
    bool enableAutoKeyExpire(uint32_t expiredInSeconds = 0);

    bool disableAutoKeyExpire();

    // compare value for key before set, to reduce the possibility of file expanding
    bool enableCompareBeforeSet();
    bool disableCompareBeforeSet();

    bool isExpirationEnabled() const { return m_enableKeyExpire; }
    bool isEncryptionEnabled() const { return m_crypter != nullptr; }
    bool isCompareBeforeSetEnabled() const { return m_enableCompareBeforeSet && !m_enableKeyExpire && !m_crypter; }

#ifdef KFKV_APPLE
#ifdef __OBJC__
    // filterExpire: return all non-expired keys, keep in mind it comes with cost
    NSArray *allKeysObjC(bool filterExpire = false);

    bool removeValuesForKeys(NSArray *arrKeys);

    typedef void (^EnumerateBlock)(NSString *key, BOOL *stop);
    void enumerateKeys(EnumerateBlock block);
#endif // __OBJC__
    // filterExpire: return all non-expired keys, keep in mind it comes with cost
    std::vector<std::string> allKeys(bool filterExpire = false);

    bool removeValuesForKeys(const std::vector<std::string> &arrKeys);

#    ifdef KFKV_IOS
    static void setIsInBackground(bool isInBackground);
    static bool isInBackground();
#    endif
#else  // !defined(KFKV_APPLE)
    // filterExpire: return all non-expired keys, keep in mind it comes with cost
    std::vector<std::string> allKeys(bool filterExpire = false);

    bool removeValuesForKeys(const std::vector<std::string> &arrKeys);
#endif // KFKV_APPLE

    bool removeValueForKey(KFKVKey_t key);

    // keepSpace: remove all keys but keep the file size not changed, running faster
    void clearAll(bool keepSpace = false);

    // KFKV's size won't reduce after deleting key-values
    // call this method after lots of deleting if you care about disk usage
    // note that `clearAll` has the similar effect of `trim`
    void trim();

    // import all key-value items from source
    // return count of items imported
    size_t importFrom(KFKV *src);

    // call this method if the instance is no longer needed in the near future
    // any subsequent call to the instance is undefined behavior
    void close();

    // call this method if you are facing memory-warning
    // any subsequent call to the instance will load all key-values from file again
    // keepSpace: remove all keys but keep the file size not changed, running faster
    void clearMemoryCache(bool keepSpace = false);

    // you don't need to call this, really, I mean it
    // unless you worry about running out of battery
    void sync(SyncFlag flag = KFKV_SYNC);

    // get exclusive access
    void lock();
    void unlock();
    bool try_lock();

    // get thread lock
#ifndef KFKV_WIN32
    void lock_thread();
    void unlock_thread();
    bool try_lock_thread();
#endif

    static const KFKVPath_t &getRootDir();

    // backup one KFKV instance from srcDir to dstDir
    // if srcDir is null, then backup from the root dir of KFKV
    static bool backupOneToDirectory(const std::string &mmapID, const KFKVPath_t &dstDir, const KFKVPath_t *srcDir = nullptr);

    // restore one KFKV instance from srcDir to dstDir
    // if dstDir is null, then restore to the root dir of KFKV
    static bool restoreOneFromDirectory(const std::string &mmapID, const KFKVPath_t &srcDir, const KFKVPath_t *dstDir = nullptr);

    // backup all KFKV instance from srcDir to dstDir
    // if srcDir is null, then backup from the root dir of KFKV
    // return count of KFKV successfully backuped
    static size_t backupAllToDirectory(const KFKVPath_t &dstDir, const KFKVPath_t *srcDir = nullptr);

    // restore all KFKV instance from srcDir to dstDir
    // if dstDir is null, then restore to the root dir of KFKV
    // return count of KFKV successfully restored
    static size_t restoreAllFromDirectory(const KFKVPath_t &srcDir, const KFKVPath_t *dstDir = nullptr);

    // check if content been changed by other process
    void checkContentChanged();

    // register a unified callback handler for KFKV
    static void registerHandler(kfkv::KFKVHandler *handler);
    static void unRegisterHandler();

    // KFKVLogInfo by default
    // pass KFKVLogNone to disable all logging
    static void setLogLevel(KFKVLogLevel level);

    // detect if the KFKV file is valid or not
    // Note: Don't use this to check the existence of the instance, the return value is undefined if the file was never created.
    static bool isFileValid(const std::string &mmapID, const KFKVPath_t *relatePath = nullptr);

    // remove the storage of the KFKV, including the data file & meta file (.crc)
    // Note: the existing instance (if any) will be closed & destroyed
    static bool removeStorage(const std::string &mmapID, const KFKVPath_t *relatePath = nullptr);

    // check the existence of the KFKV file
    static bool checkExist(const std::string &mmapID, const KFKVPath_t *relatePath = nullptr);

    // just forbid it for possibly misuse
    explicit KFKV(const KFKV &other) = delete;
    KFKV &operator=(const KFKV &other) = delete;

    friend class kfkv::NameSpace;
};

#if defined(KFKV_HAS_CPP20)
template<KFKV_SUPPORTED_VECTOR_VALUE_TYPE T>
bool KFKV::set(const T& value, KFKVKey_t key, uint32_t expireDuration) {
    if (isKeyEmpty(key)) {
        return false;
    }
    kfkv::KFKVBuffer data;
    if constexpr (std::is_same_v<T, std::vector<bool>>) {
        data = kfkv::MiniPBCoder::encodeDataWithObject(value);
    } else {
        data = kfkv::MiniPBCoder::encodeDataWithObject(std::span(value));
    }
    if (kfkv_unlikely(m_enableKeyExpire) && data.length() > 0) {
        auto tmp = kfkv::KFKVBuffer(data.length() + ConstFixed32Size);
        auto ptr = (uint8_t *) tmp.getPtr();
        memcpy(ptr, data.getPtr(), data.length());
        auto time = (expireDuration != ExpireNever) ? getCurrentTimeInSecond() + expireDuration : ExpireNever;
        memcpy(ptr + data.length(), &time, ConstFixed32Size);
        data = std::move(tmp);
    }
    return setDataForKey(std::move(data), key);
}

template<KFKV_SUPPORTED_VECTOR_VALUE_TYPE T>
bool KFKV::getVector(KFKVKey_t key, T &result) {
    if (isKeyEmpty(key)) {
        return false;
    }
    shared_lock();

    bool ret = false;
    auto data = getDataForKey(key);
    if (data.length() > 0) {
        ret = kfkv::MiniPBCoder::decodeVector(data, result);
    }

    shared_unlock();
    return ret;
}

#ifdef KFKV_APPLE
#ifdef __OBJC__
template<KFKV_SUPPORTED_VECTOR_VALUE_TYPE T>
bool getVector(std::string_view key, T &result) {
    HybridString hybridKey(key);
    return getVector(hybridKey.str, result);
}
#endif // __OBJC__
#endif // KFKV_APPLE

#endif // KFKV_HAS_CPP20

KFKV_NAMESPACE_END

namespace kfkv {

// a POD-like facade what wraps custom root directory
class KFKV_EXPORT NameSpace {
    const KFKVPath_t &m_rootDir;
    NameSpace(const KFKVPath_t &rootDir) : m_rootDir(rootDir) {}
public:
    // return the absolute root dir of NameSpace
    const KFKVPath_t &getRootDir() { return m_rootDir; }

    KFKV *kfkvWithID(const std::string &mmapID, const KFKVConfig &config);

    // mmapID: any unique ID (com.tencent.xin.pay, etc.)
    // if you want a per-user kfkv, you could merge user-id within mmapID
    // cryptKey: 16 bytes at most
    KFKV *kfkvWithID(const std::string &mmapID,
                     KFKVMode mode = KFKV_SINGLE_PROCESS,
                     const std::string *cryptKey = nullptr,
                     size_t expectedCapacity = 0,
                     bool aes256 = false);

    // backup one KFKV instance to dstDir
    bool backupOneToDirectory(const std::string &mmapID, const KFKVPath_t &dstDir);

    // restore one KFKV instance from srcDir
    bool restoreOneFromDirectory(const std::string &mmapID, const KFKVPath_t &srcDir);

    // backup all KFKV instance to dstDir
    // return count of KFKV successfully backuped
    size_t backupAllToDirectory(const KFKVPath_t &dstDir);

    // restore all KFKV instance from srcDir
    // return count of KFKV successfully restored
    size_t restoreAllFromDirectory(const KFKVPath_t &srcDir);

    // detect if the KFKV file is valid or not
    // Note: Don't use this to check the existence of the instance, the return value is undefined if the file was never created.
    bool isFileValid(const std::string &mmapID);

    // remove the storage of the KFKV, including the data file & meta file (.crc)
    // Note: the existing instance (if any) will be closed & destroyed
    bool removeStorage(const std::string &mmapID);

    // check the existence of the KFKV file
    bool checkExist(const std::string &mmapID);

    friend class KFKV_NAMESPACE_PREFIX::KFKV;
};

}

#endif // __cplusplus
#endif // KFKV_KFKV_H
