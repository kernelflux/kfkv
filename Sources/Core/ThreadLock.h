
#ifndef KFKV_THREADLOCK_H
#define KFKV_THREADLOCK_H

#ifdef  __cplusplus

#include "KFKVPredef.h"

#ifndef KFKV_WIN32
#    include <pthread.h>
#    define KFKV_USING_PTHREAD 1
#endif

#ifndef KFKV_USING_PTHREAD
#    include <atomic>
#endif

namespace kfkv {

#if KFKV_USING_PTHREAD
#    define ThreadOnceToken_t pthread_once_t
#    define ThreadOnceUninitialized PTHREAD_ONCE_INIT
#else
enum ThreadOnceTokenEnum : int32_t { ThreadOnceUninitialized = 0, ThreadOnceInitializing, ThreadOnceInitialized };
using ThreadOnceToken_t = std::atomic<ThreadOnceTokenEnum>;
#endif

class ThreadLock {
#if KFKV_USING_PTHREAD
    pthread_mutex_t m_lock;
#else
    CRITICAL_SECTION m_lock;
#endif

public:
    ThreadLock();
    ~ThreadLock();

    void initialize();

    void lock();
    void unlock();

#ifndef KFKV_WIN32
    bool try_lock();
#endif

    static void ThreadOnce(ThreadOnceToken_t *onceToken, void (*callback)(void));

#ifdef KFKV_WIN32
    static void Sleep(int ms);
#endif

    // just forbid it for possibly misuse
    explicit ThreadLock(const ThreadLock &other) = delete;
    ThreadLock &operator=(const ThreadLock &other) = delete;
};

} // namespace kfkv

#endif
#endif //KFKV_THREADLOCK_H
