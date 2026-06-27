
#ifndef KFKV_MAMERYFILE_H
#define KFKV_MAMERYFILE_H
#ifdef __cplusplus

#include "KFKVPredef.h"
#include <cstdint>
#include <functional>
#include <optional>

#ifdef KFKV_ANDROID
KFKVPath_t ashmemKFKVPathWithID(const KFKVPath_t &mmapID);

long long getFileModifyTimeInMS(const char *path);

namespace kfkv {
extern int g_android_api;
extern std::string g_android_tmpDir;

enum FileType : bool { MMFILE_TYPE_FILE = false, MMFILE_TYPE_ASHMEM = true };
} // namespace kfkv
#endif // KFKV_ANDROID

namespace kfkv {

enum class OpenFlag : uint32_t {
    ReadOnly = 1 << 0,
    WriteOnly = 1 << 1,
    ReadWrite = ReadOnly | WriteOnly,
    Create = 1 << 2,
    Excel = 1 << 3, // fail if Create is set but the file already exist
    Truncate = 1 << 4,
};
constexpr uint32_t OpenFlagRWMask = 0x3; // mask for Read Write mode

static inline OpenFlag operator | (OpenFlag left, OpenFlag right) {
    return static_cast<OpenFlag>(static_cast<uint32_t>(left) | static_cast<uint32_t>(right));
}

static inline bool operator & (OpenFlag left, OpenFlag right) {
    return ((static_cast<uint32_t>(left) & static_cast<uint32_t>(right)) != 0);
}

static inline OpenFlag operator & (OpenFlag left, uint32_t right) {
    return static_cast<OpenFlag>(static_cast<uint32_t>(left) & right);
}

template <typename T>
T roundUp(T numToRound, T multiple) {
    return ((numToRound + multiple - 1) / multiple) * multiple;
}

class FileLock;

class File {
    KFKVPath_t m_path;
#ifdef KFKV_WIN32
    std::string m_utf8Path;
#endif
    KFKVFileHandle_t m_fd;

public:
    const OpenFlag m_flag;
#ifndef KFKV_ANDROID
    explicit File(KFKVPath_t path, OpenFlag flag);
#else
    File(KFKVPath_t path, OpenFlag flag, size_t size = 0, FileType fileType = MMFILE_TYPE_FILE);
    explicit File(KFKVFileHandle_t ashmemFD);

    size_t m_size;
    const FileType m_fileType;
#endif // KFKV_ANDROID

    ~File() { close(); }

    bool open();

    void close();

    KFKVFileHandle_t getFd() const { return m_fd; }

    const KFKVPath_t &getPath() const { return m_path; }

#ifndef KFKV_WIN32
    bool isFileValid() const { return m_fd >= 0; }

    const std::string &getUTF8Path() const { return m_path; }
#else
    bool isFileValid() const { return m_fd != KFKVFileHandleInvalidValue; }

    const std::string &getUTF8Path() const { return m_utf8Path; }
#endif

    // get the actual file size on disk
    size_t getActualFileSize() const;

    // just forbid it for possibly misuse
    explicit File(const File &other) = delete;
    File &operator=(const File &other) = delete;

    friend class MemoryFile;
};

class MemoryFile {
    File m_diskFile;
#ifdef KFKV_WIN32
    HANDLE m_fileMapping;
#endif
    void *m_ptr;
    size_t m_size;
    const bool m_readOnly;
    const bool m_isMayflyFD;

    bool mmapOrCleanup(FileLock *fileLock);

    void doCleanMemoryCache(bool forceClean);

    bool openIfNeeded();

public:
#ifndef KFKV_ANDROID
    explicit MemoryFile(KFKVPath_t path, size_t expectedCapacity = 0, bool readOnly = false, bool mayflyFD = false);
#else
    MemoryFile(KFKVPath_t path, FileType fileType, size_t expectedCapacity = 0, bool readOnly = false, bool mayflyFD = false);
    explicit MemoryFile(KFKVFileHandle_t ashmemFD);

    const FileType m_fileType;
#endif // KFKV_ANDROID

    ~MemoryFile() { doCleanMemoryCache(true); }

    size_t getFileSize() const { return m_size; }

    // get the actual file size on disk
    size_t getActualFileSize();

    void *getMemory() { return m_ptr; }

    const KFKVPath_t &getPath() { return m_diskFile.getPath(); }

    const std::string &getUTF8Path() const { return m_diskFile.getUTF8Path(); }

    KFKVFileHandle_t getFd();

    void cleanMayflyFD();

    // the newly expanded file content will be zeroed
    bool truncate(size_t size, FileLock *fileLock = nullptr);

    bool msync(SyncFlag syncFlag);

    // call this if clearMemoryCache() has been called
    void reloadFromFile(size_t expectedCapacity = 0);

    void clearMemoryCache() { doCleanMemoryCache(false); }

#ifndef KFKV_WIN32
    bool isFileValid() { return (m_isMayflyFD || m_diskFile.isFileValid()) && m_size > 0 && m_ptr; }
#else
    bool isFileValid() { return (m_isMayflyFD || (m_diskFile.isFileValid() && m_fileMapping)) && m_size > 0 && m_ptr; }
#endif

    // just forbid it for possibly misuse
    explicit MemoryFile(const MemoryFile &other) = delete;
    MemoryFile &operator=(const MemoryFile &other) = delete;
};

class KFKVBuffer;

extern bool mkPath(const KFKVPath_t &path);
extern bool isFileExist(const KFKVPath_t &nsFilePath);
extern KFKVBuffer *readWholeFile(const KFKVPath_t &path);
extern bool zeroFillFile(KFKVFileHandle_t fd, size_t startPos, size_t size);
extern size_t getPageSize();
extern KFKVPath_t absolutePath(const KFKVPath_t &path);
#ifndef KFKV_WIN32
extern bool getFileSize(int fd, size_t &size);
#endif
extern bool tryAtomicRename(const KFKVPath_t &srcPath, const KFKVPath_t &dstPath);

// copy file by potentially renaming target file, might change file inode
extern bool copyFile(const KFKVPath_t &srcPath, const KFKVPath_t &dstPath);

// copy file by source file content, keep file inode the same
extern bool copyFileContent(const KFKVPath_t &srcPath, const KFKVPath_t &dstPath);
extern bool copyFileContent(const KFKVPath_t &srcPath, KFKVFileHandle_t dstFD);
extern bool copyFileContent(const KFKVPath_t &srcPath, KFKVFileHandle_t dstFD, bool needTruncate);

//#if defined(KFKV_APPLE) || defined(KFKV_WIN32)
bool isDiskOfMMAPFileCorrupted(MemoryFile *file, bool &needReportReadFail);
//#endif

bool deleteFile(const KFKVPath_t &path);

std::optional<KFKVPath_t> getUniqueFileName(const KFKVPath_t &folder, const KFKVPath_t &prefix);

enum WalkType : uint32_t {
    WalkFile = 1 << 0,
    WalkFolder = 1 << 1,
};
extern void walkInDir(const KFKVPath_t &dirPath, WalkType type, const std::function<void(const KFKVPath_t&, WalkType)> &walker);

} // namespace kfkv

#endif
#endif //KFKV_MAMERYFILE_H
