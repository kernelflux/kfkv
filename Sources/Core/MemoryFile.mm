
#include "MemoryFile.h"

#ifndef KFKV_WIN32

#    include "InterProcessLock.h"
#    include "KFKVBuffer.h"
#    include "KFKVLog.h"
#    include "ScopedLock.hpp"
#    include <cerrno>
#    include <utility>
#    include <fcntl.h>
#    include <sys/mman.h>
#    include <sys/stat.h>
#    include <unistd.h>
#    include <sys/file.h>
#    include <dirent.h>
#    include <cstring>
#    include <filesystem>
#    include <random>

using namespace std;
namespace fs = std::filesystem;

namespace kfkv {

static bool getFileSize(const char *path, size_t &size);

#    ifdef KFKV_ANDROID
extern size_t ASharedMemory_getSize(int fd);
#    else
File::File(KFKVPath_t path, OpenFlag flag) : m_path(std::move(path)), m_fd(-1), m_flag(flag) {
    open();
}

MemoryFile::MemoryFile(KFKVPath_t path, size_t expectedCapacity, bool readOnly, bool mayflyFD)
    : m_diskFile(std::move(path), readOnly ? OpenFlag::ReadOnly : (OpenFlag::ReadWrite | OpenFlag::Create))
    , m_ptr(nullptr), m_size(0), m_readOnly(readOnly), m_isMayflyFD(mayflyFD)
{
    reloadFromFile(expectedCapacity);
}
#    endif // !defined(KFKV_ANDROID)

#    ifdef KFKV_IOS
void tryResetFileProtection(const string &path);
#    endif

static int OpenFlag2NativeFlag(OpenFlag flag) {
    int native = O_CLOEXEC;
    if ((flag & OpenFlagRWMask) == OpenFlag::ReadWrite) {
        native |= O_RDWR;
    } else if (flag & OpenFlag::ReadOnly) {
        native |= O_RDONLY;
    } else if (flag & OpenFlag::WriteOnly) {
        native |= O_WRONLY;
    }

    if (flag & OpenFlag::Create) {
        native |= O_CREAT;
    }
    if (flag & OpenFlag::Excel) {
        native |= O_EXCL;
    }
    if (flag & OpenFlag::Truncate) {
        native |= O_TRUNC;
    }
    return native;
}

bool File::open() {
#    ifdef KFKV_ANDROID
    if (m_fileType == MMFILE_TYPE_ASHMEM) {
        return isFileValid();
    }
#    endif
    if (isFileValid()) {
        return true;
    }
    m_fd = ::open(m_path.c_str(), OpenFlag2NativeFlag(m_flag), S_IRWXU);
    if (!isFileValid()) {
        KFKVError("fail to open [%s], flag 0x%x, %d(%s)", m_path.c_str(), m_flag, errno, strerror(errno));
        return false;
    }
    KFKVInfo("open fd[%d], flag 0x%x, %s", m_fd, m_flag, m_path.c_str());
    return true;
}

void File::close() {
    if (isFileValid()) {
        KFKVInfo("closing fd[%d], %s", m_fd, m_path.c_str());
        if (::close(m_fd) == 0) {
            m_fd = -1;
        } else {
            KFKVError("fail to close [%s], %d(%s)", m_path.c_str(), errno, strerror(errno));
        }
    }
}

size_t File::getActualFileSize() const {
#    ifdef KFKV_ANDROID
    if (m_fileType == MMFILE_TYPE_ASHMEM) {
        return ASharedMemory_getSize(m_fd);
    }
#    endif
    size_t size = 0;
    if (isFileValid()) {
        kfkv::getFileSize(m_fd, size);
    } else {
        kfkv::getFileSize(m_path.c_str(), size);
    }
    return size;
}

bool MemoryFile::openIfNeeded() {
    if (!m_diskFile.isFileValid()) {
        return m_diskFile.open();
    }
    return true;
}

void MemoryFile::cleanMayflyFD() {
    if (m_isMayflyFD && m_diskFile.isFileValid()) {
        m_diskFile.close();
    }
}

size_t MemoryFile::getActualFileSize() {
    if (!m_isMayflyFD && !m_diskFile.isFileValid()) {
        return 0;
    }

    return m_diskFile.getActualFileSize();
}

KFKVFileHandle_t MemoryFile::getFd() {
    if (m_isMayflyFD) {
        openIfNeeded();
    }
    return m_diskFile.getFd();
}

bool MemoryFile::truncate(size_t size, FileLock *fileLock) {
    if (m_isMayflyFD) {
        openIfNeeded();
    }
    if (!m_diskFile.isFileValid()) {
        return false;
    }
    if (size == m_size) {
        return true;
    }
    if (m_readOnly) {
        // truncate readonly file not allow
        return false;
    }
#    ifdef KFKV_ANDROID
    if (m_diskFile.m_fileType == MMFILE_TYPE_ASHMEM) {
        if (size > m_size) {
            KFKVError("ashmem %s reach size limit:%zu, consider configure with larger size", m_diskFile.m_path.c_str(), m_size);
        } else {
            KFKVInfo("no way to trim ashmem %s from %zu to smaller size %zu", m_diskFile.m_path.c_str(), m_size, size);
        }
        return false;
    }
#    endif // KFKV_ANDROID

    auto oldSize = m_size;
    m_size = size;
    // round up to (n * pagesize)
    if (m_size < DEFAULT_MMAP_SIZE || (m_size % DEFAULT_MMAP_SIZE != 0)) {
        m_size = ((m_size / DEFAULT_MMAP_SIZE) + 1) * DEFAULT_MMAP_SIZE;
    }

    if (::ftruncate(m_diskFile.m_fd, static_cast<off_t>(m_size)) != 0) {
        KFKVError("fail to truncate [%s] to size %zu, %s", m_diskFile.m_path.c_str(), m_size, strerror(errno));
        m_size = oldSize;
        return false;
    }
    if (m_size > oldSize) {
        if (!zeroFillFile(m_diskFile.m_fd, oldSize, m_size - oldSize)) {
            KFKVError("fail to zeroFile [%s] to size %zu, %s", m_diskFile.m_path.c_str(), m_size, strerror(errno));
            m_size = oldSize;

            // redo ftruncate to its previous size
            int status = ::ftruncate(m_diskFile.m_fd, static_cast<off_t>(m_size));
            if (status != 0) {
                KFKVError("failed to truncate back [%s] to size %zu, %s", m_diskFile.m_path.c_str(), m_size, strerror(errno));
            } else {
                KFKVError("success to truncate [%s] back to size %zu", m_diskFile.m_path.c_str(), m_size);
                KFKVError("after truncate, file size = %zu", getActualFileSize());
            }

            return false;
        }
    }

    if (m_ptr) {
        if (munmap(m_ptr, oldSize) != 0) {
            KFKVError("fail to munmap [%s], %s", m_diskFile.m_path.c_str(), strerror(errno));
        }
    }
    return mmapOrCleanup(fileLock);
}

bool MemoryFile::msync(SyncFlag syncFlag) {
    if (m_readOnly) {
        // there's no point in msync() readonly memory
        return true;
    }
    if (m_ptr) {
        auto ret = ::msync(m_ptr, m_size, syncFlag ? MS_SYNC : MS_ASYNC);
        if (ret == 0) {
            return true;
        }
        KFKVError("fail to msync [%s], %s", m_diskFile.m_path.c_str(), strerror(errno));
    }
    return false;
}

bool MemoryFile::mmapOrCleanup(FileLock *fileLock) {
    auto oldPtr = m_ptr;
    auto mode = m_readOnly ? PROT_READ : (PROT_READ | PROT_WRITE);
    m_ptr = (char *) ::mmap(m_ptr, m_size, mode, MAP_SHARED, m_diskFile.m_fd, 0);
    if (m_ptr == MAP_FAILED) {
        KFKVError("fail to mmap [%s], mode 0x%x, %s", m_diskFile.m_path.c_str(), mode, strerror(errno));
        m_ptr = nullptr;

        doCleanMemoryCache(true);
        return false;
    }
    KFKVInfo("mmap to address [%p], oldPtr [%p], [%s]", m_ptr, oldPtr, m_diskFile.m_path.c_str());

    if (m_isMayflyFD && fileLock) {
        fileLock->destroyAndUnLock();
    }

    cleanMayflyFD();
    return true;
}

void MemoryFile::reloadFromFile(size_t expectedCapacity) {
#    ifdef KFKV_ANDROID
    if (m_fileType == MMFILE_TYPE_ASHMEM) {
        return;
    }
#    endif
    if (isFileValid()) {
        KFKVWarning("calling reloadFromFile while the cache [%s] is still valid", m_diskFile.m_path.c_str());
        KFKV_ASSERT(0);
        doCleanMemoryCache(false);
    }

    if (openIfNeeded()) {
        FileLock fileLock(m_diskFile.m_fd);
        InterProcessLock lock(&fileLock, SharedLockType);
        SCOPED_LOCK(&lock);

        kfkv::getFileSize(m_diskFile.m_fd, m_size);
        size_t expectedSize = std::max<size_t>(DEFAULT_MMAP_SIZE, roundUp<size_t>(expectedCapacity, DEFAULT_MMAP_SIZE));
        // round up to (n * pagesize)
        if (!m_readOnly && (m_size < expectedSize || (m_size % DEFAULT_MMAP_SIZE != 0))) {
            InterProcessLock exclusiveLock(&fileLock, ExclusiveLockType);
            SCOPED_LOCK(&exclusiveLock);

            size_t roundSize = ((m_size / DEFAULT_MMAP_SIZE) + 1) * DEFAULT_MMAP_SIZE;;
            roundSize = std::max<size_t>(expectedSize, roundSize);
            truncate(roundSize, &fileLock);
        } else {
            mmapOrCleanup(&fileLock);
        }
#    ifdef KFKV_IOS
        if (!m_readOnly) {
            tryResetFileProtection(m_diskFile.m_path);
        }
#    endif
    }
}

void MemoryFile::doCleanMemoryCache(bool forceClean) {
#    ifdef KFKV_ANDROID
    if (m_diskFile.m_fileType == MMFILE_TYPE_ASHMEM && !forceClean) {
        return;
    }
#    endif
    if (m_ptr && m_ptr != MAP_FAILED) {
        if (munmap(m_ptr, m_size) != 0) {
            KFKVError("fail to munmap [%s], %s", m_diskFile.m_path.c_str(), strerror(errno));
        }
    }
    m_ptr = nullptr;

    m_diskFile.close();
    m_size = 0;
}

bool isFileExist(const string &nsFilePath) {
    if (nsFilePath.empty()) {
        return false;
    }

    return access(nsFilePath.c_str(), F_OK) == 0;
}

#ifndef KFKV_APPLE
extern bool mkPath(const KFKVPath_t &str) {
    char *path = strdup(str.c_str());

    struct stat sb = {};
    bool done = false;
    char *slash = path;

    while (!done) {
        slash += strspn(slash, "/");
        slash += strcspn(slash, "/");

        done = (*slash == '\0');
        *slash = '\0';

        if (stat(path, &sb) != 0) {
            if (errno != ENOENT || mkdir(path, 0777) != 0) {
                KFKVWarning("%s : %s", path, strerror(errno));
                // there's report that some Android devices might not have access permission on parent dir
                if (done) {
                    free(path);
                    return false;
                }
                goto LContinue;
            }
        } else if (!S_ISDIR(sb.st_mode)) {
            KFKVWarning("%s: %s", path, strerror(ENOTDIR));
            free(path);
            return false;
        }
LContinue:
        *slash = '/';
    }
    free(path);

    return true;
}
#else
// avoid using so-called privacy API
extern bool mkPath(const KFKVPath_t &str) {
    auto path = [NSString stringWithUTF8String:str.c_str()];
    NSError *error = nil;
    auto ret = [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
    if (!ret) {
        KFKVWarning("%s", error.localizedDescription.UTF8String);
        return false;
    }
    return true;
}
#endif

KFKVBuffer *readWholeFile(const KFKVPath_t &path) {
    KFKVBuffer *buffer = nullptr;
    int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        auto fileLength = lseek(fd, 0, SEEK_END);
        if (fileLength > 0) {
            buffer = new KFKVBuffer(static_cast<size_t>(fileLength));
            lseek(fd, 0, SEEK_SET);
            auto readSize = read(fd, buffer->getPtr(), static_cast<size_t>(fileLength));
            if (readSize != -1) {
                //fileSize = readSize;
            } else {
                KFKVWarning("fail to read %s: %s", path.c_str(), strerror(errno));

                delete buffer;
                buffer = nullptr;
            }
        }
        close(fd);
    } else {
        KFKVWarning("fail to open %s: %s", path.c_str(), strerror(errno));
    }
    return buffer;
}

bool zeroFillFile(int fd, size_t startPos, size_t size) {
    if (fd < 0) {
        return false;
    }

    if (lseek(fd, static_cast<off_t>(startPos), SEEK_SET) < 0) {
        KFKVError("fail to lseek fd[%d], error:%s", fd, strerror(errno));
        return false;
    }

    static const char zeros[4096] = {};
    while (size >= sizeof(zeros)) {
        if (write(fd, zeros, sizeof(zeros)) < 0) {
            KFKVError("fail to write fd[%d], error:%s", fd, strerror(errno));
            return false;
        }
        size -= sizeof(zeros);
    }
    if (size > 0) {
        if (write(fd, zeros, size) < 0) {
            KFKVError("fail to write fd[%d], error:%s", fd, strerror(errno));
            return false;
        }
    }
    return true;
}

#ifndef KFKV_APPLE

bool getFileSize(int fd, size_t &size) {
    struct stat st = {};
    if (fstat(fd, &st) != -1) {
        size = (size_t) st.st_size;
        return true;
    }
    return false;
}

bool getFileSize(const char *path, size_t &size) {
    struct stat st = {};
    if (stat(path, &st) != -1) {
        size = (size_t) st.st_size;
        return true;
    }
    return false;
}

#else // !KFKV_APPLE

// avoid using so-called privacy API
bool getFileSize(int fd, size_t &size) {
    auto cur = lseek(fd, 0, SEEK_CUR);
    if (cur == -1) {
        return false;
    }
    auto end = lseek(fd, 0, SEEK_END);
    if (end == -1) {
        return false;
    }
    size = (size_t) end;

    lseek(fd, cur, SEEK_SET);
    return true;
}

bool getFileSize(const char *path, size_t &size) {
    auto fd = open(path, O_RDONLY);
    if (fd >= 0) {
        auto ret = getFileSize(fd, size);
        close(fd);
        return ret;
    }
    return false;
}

#endif // !KFKV_APPLE

size_t getPageSize() {
    return static_cast<size_t>(getpagesize());
}

extern KFKVPath_t absolutePath(const KFKVPath_t &path) {
    fs::path relative_path(path);
    fs::path absolute_path = fs::absolute(relative_path);
    try {
        fs::path normalized = fs::weakly_canonical(absolute_path);
        return normalized.string();
    } catch (std::exception &e) {
        KFKVError("fail to weakly_canonical() path %s, error: %s", absolute_path.c_str(), e.what());
    }
    return absolute_path.string();
}

#ifndef KFKV_APPLE

static pair<KFKVPath_t, int> createUniqueTempFile(const char *prefix) {
    char path[PATH_MAX];
#ifdef KFKV_ANDROID
    snprintf(path, PATH_MAX, "%s/%s.XXXXXX", g_android_tmpDir.c_str(), prefix);
#else
    snprintf(path, PATH_MAX, "%s/%s.XXXXXX", P_tmpdir, prefix);
#endif

    auto fd = mkstemp(path);
    if (fd < 0) {
        KFKVError("fail to create unique temp file [%s], %d(%s)", path, errno, strerror(errno));
        return {"", fd};
    }
    KFKVDebug("create unique temp file [%s] with fd[%d]", path, fd);
    return {KFKVPath_t(path), fd};
}

#if !defined(KFKV_ANDROID) && !defined(KFKV_LINUX)

bool tryAtomicRename(const KFKVPath_t &srcPath, const KFKVPath_t &dstPath) {
    if (::rename(srcPath.c_str(), dstPath.c_str()) != 0) {
        KFKVError("fail to rename [%s] to [%s], %d(%s)", srcPath.c_str(), dstPath.c_str(), errno, strerror(errno));
        return false;
    }
    return true;
}

bool copyFileContent(const KFKVPath_t &srcPath, KFKVFileHandle_t dstFD, bool needTruncate) {
    if (dstFD < 0) {
        return false;
    }
    bool ret = false;
    File srcFile(srcPath, OpenFlag::ReadOnly);
    if (!srcFile.isFileValid()) {
        return false;
    }
    auto bufferSize = getPageSize();
    auto buffer = (char *) malloc(bufferSize);
    if (!buffer) {
        KFKVError("fail to malloc size %zu, %d(%s)", bufferSize, errno, strerror(errno));
        goto errorOut;
    }
    lseek(dstFD, 0, SEEK_SET);

    // the POSIX standard don't have sendfile()/fcopyfile() equivalent, do it the hard way
    while (true) {
        auto sizeRead = read(srcFile.getFd(), buffer, bufferSize);
        if (sizeRead < 0) {
            KFKVError("fail to read file [%s], %d(%s)", srcPath.c_str(), errno, strerror(errno));
            goto errorOut;
        }

        size_t totalWrite = 0;
        do {
            auto sizeWrite = write(dstFD, buffer + totalWrite, sizeRead - totalWrite);
            if (sizeWrite < 0) {
                KFKVError("fail to write fd [%d], %d(%s)", dstFD, errno, strerror(errno));
                goto errorOut;
            }
            totalWrite += sizeWrite;
        } while (totalWrite < sizeRead);

        if (sizeRead < bufferSize) {
            break;
        }
    }
    if (needTruncate) {
        size_t dstFileSize = 0;
        getFileSize(dstFD, dstFileSize);
        auto srcFileSize = srcFile.getActualFileSize();
        if ((dstFileSize != srcFileSize) && (::ftruncate(dstFD, static_cast<off_t>(srcFileSize)) != 0)) {
            KFKVError("fail to truncate [%d] to size [%zu], %d(%s)", dstFD, srcFileSize, errno, strerror(errno));
            goto errorOut;
        }
    }

    ret = true;
    KFKVInfo("copy content from %s to fd[%d] finish", srcPath.c_str(), dstFD);

errorOut:
    free(buffer);
    return ret;
}

#endif // !defined(KFKV_ANDROID) && !defined(KFKV_LINUX)

// copy to a temp file then rename it
// this is the best we can do under the POSIX standard
bool copyFile(const KFKVPath_t &srcPath, const KFKVPath_t &dstPath) {
    auto pair = createUniqueTempFile("KFKV");
    auto tmpFD = pair.second;
    auto &tmpPath = pair.first;
    if (tmpFD < 0) {
        return false;
    }

    bool renamed = false;
    if (copyFileContent(srcPath, tmpFD, false)) {
        KFKVInfo("copyfile [%s] to [%s]", srcPath.c_str(), tmpPath.c_str());
        renamed = tryAtomicRename(tmpPath, dstPath);
        if (!renamed) {
            KFKVInfo("rename fail, try copy file content instead.");
            if (copyFileContent(tmpPath, dstPath)) {
                renamed = true;
                ::unlink(tmpPath.c_str());
            }
        }
        if (renamed) {
            KFKVInfo("copyfile [%s] to [%s] finish.", srcPath.c_str(), dstPath.c_str());
        }
    }

    ::close(tmpFD);
    if (!renamed) {
        ::unlink(tmpPath.c_str());
    }
    return renamed;
}

bool copyFileContent(const KFKVPath_t &srcPath, const KFKVPath_t &dstPath) {
    File dstFile(dstPath, OpenFlag::WriteOnly | OpenFlag::Create | OpenFlag::Truncate);
    if (!dstFile.isFileValid()) {
        return false;
    }
    auto ret = copyFileContent(srcPath, dstFile.getFd(), false);
    if (!ret) {
        KFKVError("fail to copyfile(): target file %s", dstPath.c_str());
    } else {
        KFKVInfo("copy content from %s to [%s] finish", srcPath.c_str(), dstPath.c_str());
    }
    return ret;
}

bool copyFileContent(const KFKVPath_t &srcPath, KFKVFileHandle_t dstFD) {
    return copyFileContent(srcPath, dstFD, true);
}

#endif // !defined(KFKV_APPLE)

void walkInDir(const KFKVPath_t &dirPath, WalkType type, const function<void(const KFKVPath_t&, WalkType)> &walker) {
    auto folderPathStr = dirPath.data();
    DIR *dir = opendir(folderPathStr);
    if (!dir) {
        KFKVError("opendir failed: %d(%s), %s", errno, strerror(errno), dirPath.c_str());
        return;
    }

    char childPath[PATH_MAX];
    size_t folderPathLength = dirPath.size();
    strncpy(childPath, folderPathStr, folderPathLength + 1);
    if (folderPathStr[folderPathLength - 1] != '/') {
        childPath[folderPathLength] = '/';
        folderPathLength++;
    }

    while (auto child = readdir(dir)) {
        if ((child->d_type & DT_REG) && (type & WalkFile)) {
#if defined(_DIRENT_HAVE_D_NAMLEN) || defined(__APPLE__)
            stpcpy(childPath + folderPathLength, child->d_name);
            childPath[folderPathLength + child->d_namlen] = 0;
#else
            strcpy(childPath + folderPathLength, child->d_name);
#endif
            walker(childPath, WalkFile);
        } else if ((child->d_type & DT_DIR) && (type & WalkFolder)) {
#if defined(_DIRENT_HAVE_D_NAMLEN) || defined(__APPLE__)
            if ((child->d_namlen == 1 && child->d_name[0] == '.') ||
                (child->d_namlen == 2 && child->d_name[0] == '.' && child->d_name[1] == '.')) {
                continue;
            }
            stpcpy(childPath + folderPathLength, child->d_name);
            childPath[folderPathLength + child->d_namlen] = 0;
#else
            if (strcmp(child->d_name, ".") == 0 || strcmp(child->d_name, "..") == 0) {
                continue;
            }
            strcpy(childPath + folderPathLength, child->d_name);
#endif
            walker(childPath, WalkFolder);
        }
    }

    closedir(dir);
}

bool deleteFile(const KFKVPath_t &path) {
    auto filename = path.c_str();
    if (::unlink(filename) != 0) {
        auto err = errno;
        KFKVError("fail to delete file [%s], %d (%s)", filename, err, strerror(err));
        return false;
    }
    return true;
}

#ifndef KFKV_APPLE
bool isDiskOfMMAPFileCorrupted(MemoryFile *file, bool &needReportReadFail) {
    // TODO: maybe we need reading a larger chunk than 4 byte in Android/Linux
    uint32_t info;
    auto fd = file->getFd();
    auto path = file->getPath().c_str();

    auto oldPos = lseek(fd, 0, SEEK_CUR);
    lseek(fd, 0, SEEK_SET);
    auto size = read(fd, &info, sizeof(info));
    auto err = errno;
    lseek(fd, oldPos, SEEK_SET);

    if (size <= 0) {
        needReportReadFail = true;
        KFKVError("fail to read [%s] from fd [%d], errno: %d (%s)", path, fd, err, strerror(err));
        if (err == EIO || err == EILSEQ || err == EINVAL || err == ENXIO) {
            KFKVWarning("file fail to read, consider it illegal, delete now: [%s]", path);
            return true;
        }
    }
    file->cleanMayflyFD();
    return false;
}
#endif

std::optional<KFKVPath_t> getUniqueFileName(const KFKVPath_t &folder, const KFKVPath_t &prefix) {
    fs::path folderPath(folder);
    fs::path prefixPath(prefix);

    // Ensure the directory exists
    std::error_code ec;
    if (!fs::exists(folderPath, ec)) {
        // Attempt to create it or fail if preferred.
        // GetTempFileName fails if dir doesn't exist, so we adhere to that.
        return std::nullopt;
    }

    // Behavior: Generate random unique filename, CREATE the file to reserve it.
    std::random_device rd;
    std::mt19937_64 gen(rd());
    std::uniform_int_distribution<uint64_t> dis;

    constexpr int maxAttempts = 64;
    for (int i = 0; i < maxAttempts; ++i) {
        uint64_t randomVal = dis(gen);
        KFKVPath_t suffix = to_string(randomVal);
        KFKVPath_t fileName = prefix + "." + suffix + ".tmp";
        fs::path candidatePath = folderPath / fileName;

        // Atomic check and create logic "mimic"
        // std::filesystem::exists is not atomic, but standard C++17 <fstream> doesn't
        // support O_EXCL (exclusive create) easily without platform headers.
        // We check existence first to avoid clobbering existing files.
        if (fs::exists(candidatePath, ec)) {
            continue; // Collision found, try next
        }

        // Try to create the file to "reserve" it
        File file(candidatePath.native(), OpenFlag::ReadWrite | OpenFlag::Create);
        if (file.isFileValid()) {
            return candidatePath.native();
        }
    }

    // Failed to find unique name after max attempts
    return std::nullopt;
}
} // namespace kfkv

#endif // !defined(KFKV_WIN32)
