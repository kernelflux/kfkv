
#include "KFKVLog.h"
#ifdef KFKV_WIN32
#include <windows.h>
#endif // KFKV_WIN32


KFKV_NAMESPACE_BEGIN

#ifdef KFKV_DEBUG
KFKVLogLevel g_currentLogLevel = KFKVLogDebug;
#else
KFKVLogLevel g_currentLogLevel = KFKVLogInfo;
#endif

#ifndef __FILE_NAME__
const char *_getFileName(const char *path) {
    const char *ptr = strrchr(path, '/');
    if (!ptr) {
        ptr = strrchr(path, '\\');
    }
    if (ptr) {
        return ptr + 1;
    } else {
        return path;
    }
}
#endif

kfkv::KFKVHandler *g_handler = nullptr;

KFKV_NAMESPACE_END


#ifdef ENABLE_KFKV_LOG
#    include <cstdarg>
#    include <string>

using namespace kfkv;

#    ifndef KFKV_ANDROID

static const char *KFKVLogLevelDesc(KFKVLogLevel level) {
    switch (level) {
        case KFKVLogDebug:
            return "D";
        case KFKVLogInfo:
            return "I";
        case KFKVLogWarning:
            return "W";
        case KFKVLogError:
            return "E";
        default:
            return "N";
    }
}

#        ifdef KFKV_APPLE

void _KFKVLogWithLevel(KFKVLogLevel level, const char *filename, const char *func, int line, const char *format, ...) {
    if (level >= g_currentLogLevel) {
        NSString *nsFormat = [NSString stringWithUTF8String:format];
        va_list argList;
        va_start(argList, format);
        NSString *message = [[NSString alloc] initWithFormat:nsFormat arguments:argList];
        va_end(argList);

        if (g_handler) {
            g_handler->kfkvLog(level, filename, line, func, message);
        } else {
            NSLog(@"[%s] <%s:%d::%s> %@", KFKVLogLevelDesc(level), filename, line, func, message);
        }
    }
}

#        else

#if defined(KFKV_WIN32)
// Helper to write raw bytes or convert to WideChar based on destination
static void WriteUTF8ToStream(const char* utf8_str) {
    HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD consoleMode;

    if (GetConsoleMode(hOut, &consoleMode)) {
        // --- CONSOLE: Convert to UTF-16 and write ---
        int wlen = MultiByteToWideChar(CP_UTF8, 0, utf8_str, -1, NULL, 0);
        if (wlen > 0) {
            wchar_t* wbuf = (wchar_t*)malloc(wlen * sizeof(wchar_t));
            if (wbuf) {
                MultiByteToWideChar(CP_UTF8, 0, utf8_str, -1, wbuf, wlen);
                WriteConsoleW(hOut, wbuf, wlen - 1, NULL, NULL);
                free(wbuf);
            }
        }
    } else {
        // --- FILE/PIPE: Write raw UTF-8 bytes ---
        DWORD bytesWritten;
        WriteFile(hOut, utf8_str, (DWORD)strlen(utf8_str), &bytesWritten, NULL);
    }
}

// Main VarArg Function
static void PrintUTF8(const char* format, ...) {
    va_list args;

    // 1. Calculate required length
    // We pass NULL/0 to vsnprintf just to get the required size (excluding null terminator)
    va_start(args, format);
    int len = vsnprintf(NULL, 0, format, args);
    va_end(args);

    if (len < 0) return; // Encoding error or invalid format

    // 2. Allocate buffer (len + 1 for null terminator)
    // Using malloc ensures we don't overflow the stack with huge strings
    char* buf = (char*)malloc(len + 1);
    if (!buf) return; // Out of memory

    // 3. Format the string into the buffer
    va_start(args, format);
    vsnprintf(buf, len + 1, format, args);
    va_end(args);

    // 4. Send to output helper
    WriteUTF8ToStream(buf);

    // 5. Cleanup
    free(buf);
}
#endif

void _KFKVLogWithLevel(KFKVLogLevel level, const char *filename, const char *func, int line, const char *format, ...) {
    if (level >= g_currentLogLevel) {
        std::string message;
        char buffer[16];

        va_list args;
        va_start(args, format);
        auto length = std::vsnprintf(buffer, sizeof(buffer), format, args);
        va_end(args);

        if (length < 0) { // something wrong
            message = {};
        } else if (length < sizeof(buffer)) {
            message = std::string(buffer, static_cast<unsigned long>(length));
        } else {
            message.resize(static_cast<unsigned long>(length), '\0');
            va_start(args, format);
            std::vsnprintf(const_cast<char *>(message.data()), static_cast<size_t>(length) + 1, format, args);
            va_end(args);
        }

        if (g_handler) {
            g_handler->kfkvLog(level, filename, line, func, message);
        } else {
#if defined(KFKV_WIN32)
            PrintUTF8("[%s] <%s:%d::%s> %s\n", KFKVLogLevelDesc(level), filename, line, func, message.c_str());
#else
            printf("[%s] <%s:%d::%s> %s\n", KFKVLogLevelDesc(level), filename, line, func, message.c_str());
#endif
            //fflush(stdout);
        }
    }
}

#        endif // KFKV_APPLE

#    endif // KFKV_ANDROID

#endif // ENABLE_KFKV_LOG
