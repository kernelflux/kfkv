
#ifndef KFKV_KFKVLOG_H
#define KFKV_KFKVLOG_H
#ifdef __cplusplus

#include "KFKVPredef.h"
#include "KFKVHandler.h"

#include <cerrno>
#include <cstdint>
#include <cstring>

//#ifdef KFKV_WIN32
//void _KFKVLogWithLevel(
//    KFKV_NAMESPACE_PREFIX::KFKVLogLevel level, const char *filename, const char *func, int line, const wchar_t *format, ...);
//#endif

void _KFKVLogWithLevel(
    KFKV_NAMESPACE_PREFIX::KFKVLogLevel level, const char* filename, const char* func, int line, const char* format, ...);

KFKV_NAMESPACE_BEGIN

extern KFKVLogLevel g_currentLogLevel;
extern kfkv::KFKVHandler *g_handler;

// enable logging
#define ENABLE_KFKV_LOG

#ifdef ENABLE_KFKV_LOG

//#ifdef KFKV_WIN32
//#define KFKV_LOG_FORMAT_PREFIX(format) L##format
//#else
//#define KFKV_LOG_FORMAT_PREFIX(format) format
//#endif

#    ifdef __FILE_NAME__
#        define __KFKV_FILE_NAME__ __FILE_NAME__
#    else
const char *_getFileName(const char *path);
#        define __KFKV_FILE_NAME__ KFKV_NAMESPACE_PREFIX::_getFileName(__FILE__)
#    endif

#    define KFKVError(format, ...)                                                                                     \
        _KFKVLogWithLevel(KFKV_NAMESPACE_PREFIX::KFKVLogError, __KFKV_FILE_NAME__, __func__, __LINE__, format,         \
                          ##__VA_ARGS__)
#    define KFKVWarning(format, ...)                                                                                   \
        _KFKVLogWithLevel(KFKV_NAMESPACE_PREFIX::KFKVLogWarning, __KFKV_FILE_NAME__, __func__, __LINE__, format,       \
                          ##__VA_ARGS__)
#    define KFKVInfo(format, ...)                                                                                      \
        _KFKVLogWithLevel(KFKV_NAMESPACE_PREFIX::KFKVLogInfo, __KFKV_FILE_NAME__, __func__, __LINE__, format,          \
                          ##__VA_ARGS__)

#    ifdef KFKV_DEBUG
#        define KFKVDebug(format, ...)                                                                                 \
            _KFKVLogWithLevel(KFKV_NAMESPACE_PREFIX::KFKVLogDebug, __KFKV_FILE_NAME__, __func__, __LINE__, format,     \
                              ##__VA_ARGS__)
#    else
#        define KFKVDebug(format, ...)                                                                                 \
            {}
#    endif

#else

#    define KFKVError(format, ...)                                                                                     \
        {}
#    define KFKVWarning(format, ...)                                                                                   \
        {}
#    define KFKVInfo(format, ...)                                                                                      \
        {}
#    define KFKVDebug(format, ...)                                                                                     \
        {}

#endif

KFKV_NAMESPACE_END

#endif
#endif //KFKV_KFKVLOG_H
