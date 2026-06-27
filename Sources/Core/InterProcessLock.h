
#ifndef KFKV_INTERPROCESSLOCK_H
#define KFKV_INTERPROCESSLOCK_H
#ifdef __cplusplus

#    include "KFKVPredef.h"

#    include <fcntl.h>

namespace kfkv {

enum LockType {
    SharedLockType,
    ExclusiveLockType,
};

// a recursive POSIX file-lock wrapper
// handles lock upgrade & downgrade correctly
class FileLock {
    KFKVFileHandle_t m_fd;
    size_t m_sharedLockCount;
    size_t m_exclusiveLockCount;

    bool doLock(LockType lockType, bool wait, bool *tryAgain = nullptr);
    bool platformLock(LockType lockType, bool wait, bool unLockFirstIfNeeded, bool *tryAgain);
    bool platformUnLock(bool unLockFirstIfNeeded);

#    ifndef KFKV_WIN32
    bool isFileLockValid() const { return m_fd >= 0; }
#        ifdef KFKV_ANDROID
    const bool m_useFcntlLock; // fcntl(F_OFD_SETLK)
    const bool m_isAshmem; // fcntl(F_SETLK)
    struct flock m_lockInfo;
    bool fcntlLock(LockType lockType, bool wait, bool unLockFirstIfNeeded, bool *tryAgain);
    bool fcntlUnLock(bool unLockFirstIfNeeded);
#        endif

#    else  // defined(KFKV_WIN32)
    OVERLAPPED m_overLapped;

    bool isFileLockValid() const { return m_fd != INVALID_HANDLE_VALUE; }
#    endif // KFKV_WIN32

public:
#    ifndef KFKV_WIN32
#        ifndef KFKV_ANDROID
    explicit FileLock(KFKVFileHandle_t fd) : m_fd(fd), m_sharedLockCount(0), m_exclusiveLockCount(0) {}
#        else
    // locking with pos & len only works in fcntl lock type
    explicit FileLock(KFKVFileHandle_t fd, bool useFcntlLock = false, bool isAshmem = false, int64_t lockPos = 0, int64_t lockLen = 0);
#        endif // KFKV_ANDROID
#    else      // defined(KFKV_WIN32)
    explicit FileLock(KFKVFileHandle_t fd) : m_fd(fd), m_sharedLockCount(0), m_exclusiveLockCount(0), m_overLapped{} {}
#    endif     // KFKV_WIN32
    ~FileLock();

    bool lock(LockType lockType);

    bool try_lock(LockType lockType, bool *tryAgain);

    bool unlock(LockType lockType);

    // unlock all and destroy file lock
    void destroyAndUnLock();

    // just forbid it for possibly misuse
    explicit FileLock(const FileLock &other) = delete;
    FileLock &operator=(const FileLock &other) = delete;
};

class InterProcessLock {
    FileLock *m_fileLock;
    LockType m_lockType;

public:
    InterProcessLock(FileLock *fileLock, LockType lockType)
        : m_fileLock(fileLock), m_lockType(lockType), m_enable(true) {
        KFKV_ASSERT(m_fileLock);
    }

    bool m_enable;

    void lock() {
        if (m_enable) {
            m_fileLock->lock(m_lockType);
        }
    }

    bool try_lock(bool *tryAgain = nullptr) {
        if (m_enable) {
            return m_fileLock->try_lock(m_lockType, tryAgain);
        }
        return false;
    }

    void unlock() {
        if (m_enable) {
            m_fileLock->unlock(m_lockType);
        }
    }
};

} // namespace kfkv

#endif // __cplusplus
#endif // KFKV_INTERPROCESSLOCK_H
