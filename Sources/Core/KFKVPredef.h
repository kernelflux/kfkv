
#ifndef KFKV_SRC_KFKVPREDEF_H
#define KFKV_SRC_KFKVPREDEF_H

// disable encryption & decryption to reduce some code
// #define KFKV_DISABLE_CRYPT
//#define KFKV_DISABLE_FLUTTER

// using POSIX implementation
//#define FORCE_POSIX

#ifdef __cplusplus

#include <string>
#include <vector>
#include <unordered_map>

constexpr auto KFKV_VERSION = "v2.4.0";

#ifdef DEBUG
#    define KFKV_DEBUG
#endif

#ifdef NDEBUG
#    undef KFKV_DEBUG
#endif

#if __cplusplus>=202002L
#    define KFKV_HAS_CPP20
#endif

#ifdef __ANDROID__
#    ifdef FORCE_POSIX
#        define KFKV_POSIX
#    else
#        define KFKV_ANDROID
#    endif
#elif __OHOS__
#   ifdef FORCE_POSIX
#       define KFKV_POSIX
#   else
#       define KFKV_ANDROID
#       define KFKV_OHOS
#endif
#elif __APPLE__
#    ifdef FORCE_POSIX
#        define KFKV_POSIX
#    else
#        define KFKV_APPLE
#        ifdef __ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__
#            define KFKV_IOS
#        elif __ENVIRONMENT_WATCH_OS_VERSION_MIN_REQUIRED__
#            define KFKV_WATCH
#        else
#            define KFKV_MAC
#        endif
#    endif // FORCE_POSIX
#elif __linux__ || __unix__
#    define KFKV_POSIX
#    if __linux__
#        define KFKV_LINUX
#    endif
#elif _WIN32
#    define KFKV_WIN32
#endif

#ifdef KFKV_WIN32
#    if !defined(_WIN32_WINNT)
#        define _WIN32_WINNT _WIN32_WINNT_WINXP
#    endif

#    include <SDKDDKVer.h>
// Exclude rarely-used stuff from Windows headers
#    define WIN32_LEAN_AND_MEAN
// Windows Header Files
#    include <windows.h>

constexpr auto KFKV_PATH_SLASH = L"\\";
using KFKVFileHandle_t = HANDLE;
#define KFKVFileHandleInvalidValue INVALID_HANDLE_VALUE
using KFKVPath_t = std::wstring;
extern KFKVPath_t string2KFKVPath_t(const std::string &str);
extern std::string KFKVPath_t2String(const KFKVPath_t &str);

#    ifndef KFKV_EMBED_ZLIB
#        define KFKV_EMBED_ZLIB 1
#    endif

#else // KFKV_WIN32

constexpr auto KFKV_PATH_SLASH = "/";
using KFKVFileHandle_t = int;
constexpr KFKVFileHandle_t KFKVFileHandleInvalidValue = -1;
using KFKVPath_t = std::string;
#    define string2KFKVPath_t(str) (str)
#    define KFKVPath_t2String(str) (str)

#    ifndef KFKV_EMBED_ZLIB
#        define KFKV_EMBED_ZLIB 0
#    endif

#endif // KFKV_WIN32

#ifdef KFKV_ANDROID
#define KFKV_EXPORT __attribute__((visibility("default")))
#else
#define KFKV_EXPORT
#endif

#ifdef KFKV_APPLE
#ifdef __OBJC__
#    import <Foundation/Foundation.h>
using KFKVLog_t = NSString *;
#else
using KFKVLog_t = void *;
#endif
#    define KFKV_NAMESPACE_BEGIN namespace kfkv {
#    define KFKV_NAMESPACE_END }
#    define KFKV_NAMESPACE_PREFIX kfkv
#else
#    define KFKV_NAMESPACE_BEGIN
#    define KFKV_NAMESPACE_END
#    define KFKV_NAMESPACE_PREFIX
using KFKVLog_t = const std::string &;
#endif // KFKV_APPLE

KFKV_NAMESPACE_BEGIN

enum KFKVLogLevel : int {
    KFKVLogDebug = 0, // not available for release/product build
    KFKVLogInfo = 1,  // default level
    KFKVLogWarning,
    KFKVLogError,
    KFKVLogNone, // special level used to disable all log messages
};

enum KFKVRecoverStrategic : int {
    OnErrorDiscard = 0,
    OnErrorRecover,
};

enum KFKVErrorType : int {
    KFKVCRCCheckFail = 0,
    KFKVFileLength,
};

enum SyncFlag : bool { KFKV_SYNC = true, KFKV_ASYNC = false };

KFKV_NAMESPACE_END

namespace kfkv {

extern KFKV_EXPORT size_t DEFAULT_MMAP_SIZE;
#define DEFAULT_MMAP_ID "kfkv.default"

class KFKVBuffer;
struct KeyValueHolder;

#ifdef KFKV_DISABLE_CRYPT
using KeyValueHolderCrypt = KeyValueHolder;
#else
struct KeyValueHolderCrypt;
#endif

#ifdef KFKV_APPLE

#ifdef __OBJC__
struct HybridStringCP {
    NSString *str;
    HybridStringCP(std::string_view cpp);
    ~HybridStringCP();
};

struct HybridString {
    NSString *str;
    HybridString(std::string_view cpp);
    ~HybridString();
};

struct KeyHasher {
    // enables heterogeneous lookup
    using is_transparent = void;
    size_t operator()(NSString *key) const { return key.hash; }
};

struct KeyEqualer {
    // enables heterogeneous lookup
    using is_transparent = void;
    bool operator()(NSString *left, NSString *right) const {
        if (left == right) {
            return true;
        }
        return ([left isEqualToString:right] == YES);
    }
};
using KFKVVector = std::vector<std::pair<NSString *, kfkv::KFKVBuffer>>;
using KFKVMap = std::unordered_map<NSString *, kfkv::KeyValueHolder, KeyHasher, KeyEqualer>;
using KFKVMapCrypt = std::unordered_map<NSString *, kfkv::KeyValueHolderCrypt, KeyHasher, KeyEqualer>;
#else // type erase for pure C++ users
using KFKVVector = std::vector<std::pair<void *, kfkv::KFKVBuffer>>;
using KFKVMap = std::unordered_map<void *, kfkv::KeyValueHolder>;
using KFKVMapCrypt = std::unordered_map<void *, kfkv::KeyValueHolderCrypt>;
#endif // __OBJC__

#else // !KFKV_APPLE

struct KeyHasher {
    // enables heterogeneous lookup
    using is_transparent = void;

    std::size_t operator()(const std::string_view& str) const {
        return std::hash<std::string_view>{}(str);
    }

    std::size_t operator()(const std::string& str) const {
        return std::hash<std::string>{}(str);
    }
};

struct KeyEqualer {
    // enables heterogeneous lookup
    using is_transparent = void;

    bool operator()(const std::string_view& lhs, const std::string_view& rhs) const {
        return lhs == rhs;
    }

    bool operator()(const std::string& lhs, const std::string& rhs) const {
        return lhs == rhs;
    }
};
using KFKVVector = std::vector<std::pair<std::string, kfkv::KFKVBuffer>>;
using KFKVMap = std::unordered_map<std::string, kfkv::KeyValueHolder, KeyHasher, KeyEqualer>;
using KFKVMapCrypt = std::unordered_map<std::string, kfkv::KeyValueHolderCrypt, KeyHasher, KeyEqualer>;
#endif // KFKV_APPLE

template <typename T>
void unused(const T &) {}

constexpr size_t AES_KEY_LEN = 16;
constexpr size_t AES_KEY_BITSET_LEN = 128;
constexpr size_t AES_IV_LEN = 16;
constexpr size_t AES256_KEY_LEN = 32;
constexpr size_t AES256_KEY_BITSET_LEN = 256;

} // namespace kfkv

#ifdef KFKV_DEBUG
#    include <cassert>
#    define KFKV_ASSERT(var) assert(var)
#else
#    define KFKV_ASSERT(var) kfkv::unused(var)
#endif

#endif //cplus-plus

#ifndef KFKV_WIN32
#    ifndef likely
#        define kfkv_unlikely(x) (__builtin_expect(bool(x), 0))
#        define kfkv_likely(x) (__builtin_expect(bool(x), 1))
#    endif
#else
#    ifndef likely
#        define kfkv_unlikely(x) (x)
#        define kfkv_likely(x) (x)
#    endif
#endif

#if defined(__x86_64__) || defined(_M_X64)
  #define KFKV_ABI "x86_64"
#elif defined(__aarch64__) || defined(_M_ARM64)
  #define KFKV_ABI "arm64-v8a"
#else
  #define KFKV_ABI "unknow"
//  #error "Unsupported arch."
#endif

#endif //KFKV_SRC_KFKVPREDEF_H
