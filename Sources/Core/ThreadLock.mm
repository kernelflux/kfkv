
#include "ThreadLock.h"
#include "KFKVLog.h"

#if KFKV_USING_PTHREAD

using namespace std;

namespace kfkv {

ThreadLock::ThreadLock() : m_lock({}) {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);

    pthread_mutex_init(&m_lock, &attr);

    pthread_mutexattr_destroy(&attr);
}

ThreadLock::~ThreadLock() {
    pthread_mutex_unlock(&m_lock);

    pthread_mutex_destroy(&m_lock);
}

void ThreadLock::lock() {
    auto ret = pthread_mutex_lock(&m_lock);
    if (ret != 0) {
        KFKVError("fail to lock %p, ret=%d, errno=%s", &m_lock, ret, strerror(errno));
    }
}

void ThreadLock::unlock() {
    auto ret = pthread_mutex_unlock(&m_lock);
    if (ret != 0) {
        KFKVError("fail to unlock %p, ret=%d, errno=%s", &m_lock, ret, strerror(errno));
    }
}

bool ThreadLock::try_lock() {
    auto ret = pthread_mutex_trylock(&m_lock);
    return (ret == 0);
}

void ThreadLock::initialize() {
    return;
}

void ThreadLock::ThreadOnce(ThreadOnceToken_t *onceToken, void (*callback)()) {
    pthread_once(onceToken, callback);
}

} // namespace kfkv

#endif // KFKV_USING_PTHREAD
