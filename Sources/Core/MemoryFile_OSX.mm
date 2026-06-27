
#include "MemoryFile.h"
#include "KFKVLog.h"

#ifdef KFKV_IOS

using namespace std;

namespace kfkv {

void tryResetFileProtection(const string &path) {
    @autoreleasepool {
        NSString *nsPath = [NSString stringWithUTF8String:path.c_str()];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:nsPath error:nullptr];
        NSString *protection = [attr valueForKey:NSFileProtectionKey];
        KFKVInfo("protection on [%@] is %@", nsPath, protection);
        if ([protection isEqualToString:NSFileProtectionCompleteUntilFirstUserAuthentication] == NO) {
            NSMutableDictionary *newAttr = [NSMutableDictionary dictionaryWithDictionary:attr];
            [newAttr setObject:NSFileProtectionCompleteUntilFirstUserAuthentication forKey:NSFileProtectionKey];
            NSError *err = nil;
            [[NSFileManager defaultManager] setAttributes:newAttr ofItemAtPath:nsPath error:&err];
            if (err != nil) {
                KFKVError("fail to set attribute %@ on [%@]: %@", NSFileProtectionCompleteUntilFirstUserAuthentication,
                          nsPath, err);
            }
        }
    }
}

} // namespace kfkv

#endif // KFKV_IOS

#ifdef KFKV_APPLE

#include <copyfile.h>
#include <unistd.h>

namespace kfkv {

bool tryAtomicRename(const KFKVPath_t &srcPath, const KFKVPath_t &dstPath) {
    if (srcPath.empty() || dstPath.empty()) {
        return false;
    }
    bool renamed = false;

    // try atomic swap first
    if (@available(iOS 10.0, watchOS 3.0, macOS 10.12, *)) {
        // renameat2() equivalent
        if (renamex_np(srcPath.c_str(), dstPath.c_str(), RENAME_SWAP) == 0) {
            renamed = true;
            if (srcPath != dstPath) {
                ::unlink(srcPath.c_str());
            }
        } else if (errno != ENOENT) {
            KFKVError("fail to renamex_np %s to %s, %s", srcPath.c_str(), dstPath.c_str(), strerror(errno));
        }
    }

    if (!renamed) {
        // try old style rename
        if (rename(srcPath.c_str(), dstPath.c_str()) != 0) {
            KFKVError("fail to rename %s to %s, %s", srcPath.c_str(), dstPath.c_str(), strerror(errno));
            return false;
        }
    }

    return true;
}

bool copyFile(const KFKVPath_t &srcPath, const KFKVPath_t &dstPath) {
    // prepare a temp file for atomic rename, avoid data corruption of sudden crash
    NSString *uniqueFileName = [NSString stringWithFormat:@"kfkv_%zu", (size_t) NSDate.timeIntervalSinceReferenceDate];
    NSString *tmpFile = [NSTemporaryDirectory() stringByAppendingPathComponent:uniqueFileName];
    if (copyfile(srcPath.c_str(), tmpFile.UTF8String, nullptr, COPYFILE_UNLINK | COPYFILE_CLONE) != 0) {
        KFKVError("fail to copyfile [%s] to [%s], %s", srcPath.c_str(), tmpFile.UTF8String, strerror(errno));
        return false;
    }
    KFKVInfo("copyfile [%s] to [%s]", srcPath.c_str(), tmpFile.UTF8String);

    if (tryAtomicRename(tmpFile.UTF8String, dstPath.c_str())) {
        KFKVInfo("copyfile [%s] to [%s] finish.", srcPath.c_str(), dstPath.c_str());
        return true;
    }

    KFKVInfo("rename fail, try copy file content instead.");
    auto ret = copyFileContent(tmpFile.UTF8String, dstPath);

    unlink(tmpFile.UTF8String);
    return ret;
}

bool copyFileContent(const KFKVPath_t &srcPath, const KFKVPath_t &dstPath) {
    File dstFile(dstPath, OpenFlag::WriteOnly | OpenFlag::Create | OpenFlag::Truncate);
    if (!dstFile.isFileValid()) {
        return false;
    }
    if (copyFileContent(srcPath, dstFile.getFd())) {
        KFKVInfo("copy content from %s to fd[%s] finish", srcPath.c_str(), dstPath.c_str());
        return true;
    }
    KFKVError("fail to copyfile(): target file %s", dstPath.c_str());
    return false;
}

bool copyFileContent(const KFKVPath_t &srcPath, KFKVFileHandle_t dstFD) {
    if (dstFD < 0) {
        return false;
    }

    File srcFile(srcPath, OpenFlag::ReadOnly);
    if (!srcFile.isFileValid()) {
        return false;
    }

    // sendfile() equivalent
    if (::fcopyfile(srcFile.getFd(), dstFD, nullptr, COPYFILE_ALL) == 0) {
        KFKVInfo("copy content from %s to fd[%d] finish", srcPath.c_str(), dstFD);
        return true;
    }
    KFKVError("fail to copyfile(): %d(%s), source file %s", errno, strerror(errno), srcPath.c_str());
    return false;
}

bool copyFileContent(const KFKVPath_t &srcPath, KFKVFileHandle_t dstFD, bool needTruncate) {
    return copyFileContent(srcPath, dstFD);
}

bool isDiskOfMMAPFileCorrupted(MemoryFile *file, bool &needReportReadFail) {
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
        if (err == EDEVERR || err == EILSEQ || err == EINVAL || err == ENXIO) {
            KFKVWarning("file fail to read, consider it illegal, delete now: [%s]", path);
            return true;
        }
    }
    file->cleanMayflyFD();
    return false;
}

} // namespace kfkv

#endif // KFKV_APPLE
