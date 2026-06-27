
#ifndef KFKV_IO_h
#define KFKV_IO_h
#ifdef __cplusplus

#include "KFKV.h"

KFKV_NAMESPACE_BEGIN

std::string mmapedKVKey(const std::string &mmapID, const KFKVPath_t *rootPath = nullptr, bool alreadyAbsolute = false);
std::string legacyMmapedKVKey(const std::string &mmapID, const KFKVPath_t *rootPath = nullptr);
#ifndef KFKV_ANDROID
KFKVPath_t mappedKVPathWithID(const std::string &mmapID, const KFKVPath_t *rootPath, bool alreadyAbsolute = false);
#else
KFKVPath_t mappedKVPathWithID(const std::string &mmapID, const KFKVPath_t *rootPath, KFKVMode mode = KFKV_MULTI_PROCESS, bool alreadyAbsolute = false);
#endif
KFKVPath_t crcPathWithPath(const KFKVPath_t &kvPath);

KFKVRecoverStrategic onKFKVCRCCheckFail(const std::string &mmapID);
KFKVRecoverStrategic onKFKVFileLengthError(const std::string &mmapID);

#ifndef KFKV_WIN32
constexpr auto SPECIAL_CHARACTER_DIRECTORY_NAME = "specialCharacter";
constexpr auto CRC_SUFFIX = ".crc";
#else
constexpr auto SPECIAL_CHARACTER_DIRECTORY_NAME = L"specialCharacter";
constexpr auto CRC_SUFFIX = L".crc";
#endif

template <typename T>
void clearDictionary(T *dic) {
    if (!dic) {
        return;
    }
    dic->clear();
}

enum : bool {
    KeepSequence = false,
    IncreaseSequence = true,
};

#ifdef KFKV_ANDROID
// status of migrating old file to new file
enum class MigrateStatus: uint32_t {
    NotSpecial, // it's not specially (mistakenly) encoded
    NoneExist, // none of these files exist
    NewExist, // only new file exist
    OldToNewMigrated, // migrated, it's one time only operation
    OldToNewMigrateFail, // old file exist but fail to migrate (maybe other process opened)
    OldAndNewExist, // both old and new exist (fail to delete old file? old file migrated from old device?)
};

// historically Android mistakenly use mmapKey as mmapID, we try migrate back to normal when possible
MigrateStatus tryMigrateLegacyKFKVFile(const std::string &mmapID, const KFKVPath_t *rootPath, bool alreadyAbsolute = false);
#endif // KFKV_ANDROID

KFKV_NAMESPACE_END

#endif
#endif /* KFKV_IO_h */
