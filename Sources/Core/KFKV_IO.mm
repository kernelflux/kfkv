
#include "KFKV_IO.h"
#include "CodedInputData.h"
#include "CodedOutputData.h"
#include "InterProcessLock.h"
#include "KFKVBuffer.h"
#include "KFKVLog.h"
#include "KFKVMetaInfo.hpp"
#include "MemoryFile.h"
#include "MiniPBCoder.h"
#include "PBUtility.h"
#include "ScopedLock.hpp"
#include "ThreadLock.h"
#include "aes/AESCrypt.h"
#include "aes/openssl/openssl_aes.h"
#include "aes/openssl/openssl_md5.h"
#include "crc32/Checksum.h"
#include <algorithm>
#include <cassert>
#include <cstring>
#include <ctime>
#include <filesystem>

#ifdef KFKV_IOS
#    include "KFKV_OSX.h"
#endif

#ifdef KFKV_APPLE
#endif // KFKV_APPLE

#ifndef KFKV_WIN32
#    include <unistd.h>
#endif

using namespace std;
using namespace kfkv;
namespace fs = std::filesystem;
using KVHolderRet_t = std::pair<bool, KeyValueHolder>;
extern ThreadLock *g_instanceLock;
extern unordered_map<string, KFKV *> *g_instanceDic;
extern KFKVPath_t g_realRootDir;

KFKV_NAMESPACE_BEGIN

void KFKV::loadFromFile() {
    loadMetaInfoAndCheck();
#ifndef KFKV_DISABLE_CRYPT
    if (m_crypter) {
        if (m_metaInfo->m_version >= KFKVVersionRandomIV) {
            m_crypter->resetIV(m_metaInfo->m_vector, sizeof(m_metaInfo->m_vector));
        }
    }
#endif
    if (!m_file->isFileValid()) {
        m_file->reloadFromFile(m_expectedCapacity);
    } else if (isMultiProcess()) {
        // the file size may change by other process between instance creation and loadFromFile
        // because we have lazy load
        auto actualFileSize = m_file->getActualFileSize();
        if (actualFileSize != m_file->getFileSize()) {
            m_file->reloadFromFile(m_expectedCapacity);
        }
    }
    if (!m_file->isFileValid()) {
        KFKVError("file [%s] not valid", m_path.c_str());
    } else {
        // error checking
        bool loadFromFile = false, needFullWriteback = false;
        checkDataValid(loadFromFile, needFullWriteback);
        KFKVInfo("loading [%s] with %zu actual size, file size %zu, InterProcess %d, meta info "
                 "version:%u",
                 m_mmapID.c_str(), m_actualSize, m_file->getFileSize(), isMultiProcess(), m_metaInfo->m_version);
        auto ptr = (uint8_t *) m_file->getMemory();
        // loading
        if (loadFromFile && m_actualSize > 0) {
            KFKVInfo("loading [%s] with crc %u sequence %u version %u", m_mmapID.c_str(), m_metaInfo->m_crcDigest,
                     m_metaInfo->m_sequence, m_metaInfo->m_version);
            KFKVBuffer inputBuffer(ptr + Fixed32Size, m_actualSize, KFKVBufferNoCopy);
            if (m_crypter) {
                clearDictionary(m_dicCrypt);
            } else {
                clearDictionary(m_dic);
            }
            if (needFullWriteback) {
#ifndef KFKV_DISABLE_CRYPT
                if (m_crypter) {
                    MiniPBCoder::greedyDecodeMap(*m_dicCrypt, inputBuffer, m_crypter);
                } else
#endif
                {
                    MiniPBCoder::greedyDecodeMap(*m_dic, inputBuffer);
                }
            } else {
#ifndef KFKV_DISABLE_CRYPT
                if (m_crypter) {
                    MiniPBCoder::decodeMap(*m_dicCrypt, inputBuffer, m_crypter);
                } else
#endif
                {
                    MiniPBCoder::decodeMap(*m_dic, inputBuffer);
                }
            }
            m_output = new CodedOutputData(ptr + Fixed32Size, m_file->getFileSize() - Fixed32Size);
            m_output->seek(m_actualSize);
            if (needFullWriteback && !isReadOnly()) {
                fullWriteback();
            }
        } else {
            // file not valid or empty, discard everything
            SCOPED_LOCK(m_exclusiveProcessLock);

            m_output = new CodedOutputData(ptr + Fixed32Size, m_file->getFileSize() - Fixed32Size);
            if (isReadOnly()) {
                // do nothing
            } else if (m_actualSize > 0) {
                writeActualSize(0, 0, nullptr, IncreaseSequence);
                sync(KFKV_SYNC);
            } else {
                writeActualSize(0, 0, nullptr, KeepSequence);
            }
        }
        auto count = m_crypter ? m_dicCrypt->size() : m_dic->size();
        KFKVInfo("loaded [%s] with %zu key-values", m_mmapID.c_str(), count);
        notifyContentLoaded();
//        auto keys = allKeys();
//        for (size_t index = 0; index < count; index++) {
//            KFKVInfo("key[%llu]: %s", index, keys[index].c_str());
//        }
    }

    m_needLoadFromFile = false;
}

// read from last m_position
void KFKV::partialLoadFromFile() {
    if (!m_file->isFileValid()) {
        return;
    }
    m_metaInfo->read(m_metaFile->getMemory());

    size_t oldActualSize = m_actualSize;
    m_actualSize = readActualSize();
    auto fileSize = m_file->getFileSize();
    KFKVDebug("loading [%s] with file size %zu, oldActualSize %zu, newActualSize %zu", m_mmapID.c_str(), fileSize,
              oldActualSize, m_actualSize);

    if (m_actualSize > 0) {
        if (m_actualSize < fileSize && m_actualSize + Fixed32Size <= fileSize) {
            if (m_actualSize > oldActualSize) {
                auto position = oldActualSize;
                size_t addedSize = m_actualSize - position;
                auto basePtr = (uint8_t *) m_file->getMemory() + Fixed32Size;
                // incremental update crc digest
                m_crcDigest = (uint32_t) CRC32(m_crcDigest, basePtr + position, (z_size_t) addedSize);
                if (m_crcDigest == m_metaInfo->m_crcDigest) {
                    KFKVBuffer inputBuffer(basePtr, m_actualSize, KFKVBufferNoCopy);
#ifndef KFKV_DISABLE_CRYPT
                    if (m_crypter) {
                        MiniPBCoder::greedyDecodeMap(*m_dicCrypt, inputBuffer, m_crypter, position);
                    } else
#endif
                    {
                        MiniPBCoder::greedyDecodeMap(*m_dic, inputBuffer, position);
                    }
                    m_output->seek(addedSize);
                    m_hasFullWriteback = false;

                    [[maybe_unused]] auto count = m_crypter ? m_dicCrypt->size() : m_dic->size();
                    KFKVDebug("partial loaded [%s] with %zu values", m_mmapID.c_str(), count);
                    return;
                } else {
                    KFKVError("m_crcDigest[%u] != m_metaInfo->m_crcDigest[%u]", m_crcDigest, m_metaInfo->m_crcDigest);
                }
            }
        }
    }
    // something is wrong, do a full load
    clearMemoryCache();
    loadFromFile();
}

static bool deleteOrRenameFile(const KFKVPath_t &src) {
    if (!deleteFile(src)) {
        fs::path path = src;
        auto folder = path.parent_path().native();
        auto filename = path.filename().native();
        if (auto tmpPath = getUniqueFileName(folder, filename)) {
            return tryAtomicRename(src, tmpPath.value());
        }
        return false;
    }
    return true;
}

bool KFKV::checkFileHasDiskError() {
    if (m_isSecondLoad) {
        return false;
    }
    m_isSecondLoad = true;

    bool needReportReadFail = false;
    if (isDiskOfMMAPFileCorrupted(m_metaFile, needReportReadFail)) {
        m_metaFile->clearMemoryCache();
        deleteOrRenameFile(m_metaFile->getPath());
        m_metaFile->reloadFromFile();
    }

    if (!m_file->isFileValid()) {
        m_file->reloadFromFile(m_expectedCapacity);
    }
    if (!m_file->isFileValid()) {
        KFKVError("file [%s] not valid", m_file->getPath().c_str());
        return false;
    }
    if (isDiskOfMMAPFileCorrupted(m_file, needReportReadFail)) {
        m_file->clearMemoryCache();
        deleteOrRenameFile(m_file->getPath());
        m_file->reloadFromFile(m_expectedCapacity);
    }
    return needReportReadFail;
}

void KFKV::loadMetaInfoAndCheck() {
    if (!m_metaFile->isFileValid()) {
        m_metaFile->reloadFromFile();
    }
    if (!m_metaFile->isFileValid()) {
        KFKVError("file [%s] not valid", m_metaFile->getPath().c_str());
        return;
    }

    if (checkFileHasDiskError()) {
        // let user know?
    }

    // check again, the meta file might get reloaded
    if (!m_metaFile->isFileValid()) {
        KFKVError("file [%s] not valid", m_metaFile->getPath().c_str());
        return;
    }

    m_metaInfo->read(m_metaFile->getMemory());

    if (isReadOnly()) {
        return;
    }

    // the meta file is in specious status
    if (m_metaInfo->m_version >= KFKVVersionHolder) {
        KFKVWarning("meta file [%s] in specious state, version %u, flags 0x%llx", m_mmapID.c_str(),
                    m_metaInfo->m_version, m_metaInfo->m_flags);

        // KFKVVersionActualSize is the last version we don't check meta file
        m_metaInfo->m_version = KFKVVersionActualSize;
        m_metaInfo->m_flags = 0;
        m_metaInfo->write(m_metaFile->getMemory());
    }

    if (m_metaInfo->m_version >= KFKVVersionFlag) {
        m_enableKeyExpire = m_metaInfo->hasFlag(KFKVMetaInfo::EnableKeyExipre);
        if (m_enableKeyExpire && m_enableCompareBeforeSet) {
            KFKVError("enableCompareBeforeSet will be invalid when Expiration is on");
            m_enableCompareBeforeSet = false;
        }
        KFKVInfo("meta file [%s] has flag [%llu]", m_mmapID.c_str(), m_metaInfo->m_flags);
    } else {
        if (m_metaInfo->m_flags != 0) {
            m_metaInfo->m_flags = 0;
            m_metaInfo->write(m_metaFile->getMemory());
        }
    }
}

void KFKV::checkDataValid(bool &loadFromFile, bool &needFullWriteback) {
    // try auto recover from last confirmed location
    auto fileSize = m_file->getFileSize();
    auto checkLastConfirmedInfo = [&] {
        if (m_metaInfo->m_version >= KFKVVersionActualSize) {
            // downgrade & upgrade support
            uint32_t oldStyleActualSize = 0;
            memcpy(&oldStyleActualSize, m_file->getMemory(), Fixed32Size);
            if (oldStyleActualSize != m_actualSize) {
                KFKVWarning("oldStyleActualSize %u not equal to meta actual size %lu", oldStyleActualSize,
                            m_actualSize);
                if (oldStyleActualSize < fileSize && (oldStyleActualSize + Fixed32Size) <= fileSize) {
                    if (checkFileCRCValid(oldStyleActualSize, m_metaInfo->m_crcDigest)) {
                        KFKVInfo("looks like [%s] been downgrade & upgrade again", m_mmapID.c_str());
                        loadFromFile = true;
                        writeActualSize(oldStyleActualSize, m_metaInfo->m_crcDigest, nullptr, KeepSequence);
                        return;
                    }
                } else {
                    KFKVWarning("oldStyleActualSize %u greater than file size %lu", oldStyleActualSize, fileSize);
                }
            }

            auto lastActualSize = m_metaInfo->m_lastConfirmedMetaInfo.lastActualSize;
            if (lastActualSize < fileSize && (lastActualSize + Fixed32Size) <= fileSize) {
                auto lastCRCDigest = m_metaInfo->m_lastConfirmedMetaInfo.lastCRCDigest;
                if (checkFileCRCValid(lastActualSize, lastCRCDigest)) {
                    loadFromFile = true;
                    writeActualSize(lastActualSize, lastCRCDigest, nullptr, KeepSequence);
                } else {
                    KFKVError("check [%s] error: lastActualSize %u, lastActualCRC %u", m_mmapID.c_str(), lastActualSize,
                              lastCRCDigest);
                }
            } else {
                KFKVError("check [%s] error: lastActualSize %u, file size is %u", m_mmapID.c_str(), lastActualSize,
                          fileSize);
            }
        }
    };

    m_actualSize = readActualSize();

    if (m_actualSize < fileSize && (m_actualSize + Fixed32Size) <= fileSize) {
        if (checkFileCRCValid(m_actualSize, m_metaInfo->m_crcDigest)) {
            loadFromFile = true;
        } else {
            checkLastConfirmedInfo();
            if (!loadFromFile) {

                auto strategic = onKFKVCRCCheckFail(m_mmapID);
                strategic = m_recoverStrategic.has_value() ? m_recoverStrategic.value() : strategic;
                if (strategic == OnErrorRecover) {
                    loadFromFile = true;
                    needFullWriteback = true;
                }
                KFKVInfo("recover strategic for [%s] is %d", m_mmapID.c_str(), strategic);
            }
        }
    } else {
        KFKVError("check [%s] error: %zu size in total, file size is %zu", m_mmapID.c_str(), m_actualSize, fileSize);

        checkLastConfirmedInfo();

        if (!loadFromFile) {
            auto strategic = onKFKVFileLengthError(m_mmapID);
            strategic = m_recoverStrategic.has_value() ? m_recoverStrategic.value() : strategic;
            if (strategic == OnErrorRecover) {
                // make sure we don't over read the file
                m_actualSize = fileSize - Fixed32Size;
                loadFromFile = true;
                needFullWriteback = true;
            }
            KFKVInfo("recover strategic for [%s] is %d", m_mmapID.c_str(), strategic);
        }
    }
}

void KFKV::checkLoadData() {
    if (m_needLoadFromFile) {
        SCOPED_LOCK(m_sharedProcessLock);

        m_needLoadFromFile = false;
        loadFromFile();
        return;
    }
    if (!isMultiProcess()) {
        return;
    }

    if (!m_metaFile->isFileValid()) {
        return;
    }
    SCOPED_LOCK(m_sharedProcessLock);

    KFKVMetaInfo metaInfo;
    metaInfo.read(m_metaFile->getMemory());
    if (m_metaInfo->m_sequence != metaInfo.m_sequence) {
        KFKVInfo("[%s] oldSeq %u, newSeq %u", m_mmapID.c_str(), m_metaInfo->m_sequence, metaInfo.m_sequence);
        SCOPED_LOCK(m_sharedProcessLock);

        clearMemoryCache();
        loadFromFile();
        notifyContentChanged();
    } else if ((m_metaInfo->m_crcDigest != metaInfo.m_crcDigest) || (m_metaInfo->m_actualSize != metaInfo.m_actualSize)) {
        KFKVDebug("[%s] crcDigest %u -> %u, actualSize %u -> %u", m_mmapID.c_str(), m_metaInfo->m_crcDigest,
                  metaInfo.m_crcDigest, m_metaInfo->m_actualSize, metaInfo.m_actualSize);
        SCOPED_LOCK(m_sharedProcessLock);

        // looks like this is no longer needed
        // for we inc sequence on truncate()/trim()/expandAndWriteBack()/fullWriteBack() etc
        /*size_t fileSize = m_file->getActualFileSize();
        if (m_file->getFileSize() != fileSize) {
            KFKVInfo("file size has changed [%s] from %zu to %zu", m_mmapID.c_str(), m_file->getFileSize(), fileSize);
            clearMemoryCache();
            loadFromFile();
        } else*/ {
            partialLoadFromFile();
        }
        notifyContentChanged();
    }
}

constexpr uint32_t ItemSizeHolderSize = 4;

static pair<KFKVBuffer, size_t> prepareEncode(const KFKVMap &dic) {
    // make some room for placeholder
    size_t totalSize = ItemSizeHolderSize;
    for (auto &itr : dic) {
        auto &kvHolder = itr.second;
        totalSize += kvHolder.computedKVSize + kvHolder.valueSize;
    }
    return make_pair(KFKVBuffer(), totalSize);
}

#ifndef KFKV_DISABLE_CRYPT
static pair<KFKVBuffer, size_t> prepareEncode(const KFKVMapCrypt &dic) {
    KFKVVector vec;
    size_t totalSize = 0;
    // make some room for placeholder
    uint32_t smallestOffet = 5 + 1; // 5 is the largest size needed to encode varint32
    for (auto &itr : dic) {
        auto &kvHolder = itr.second;
        if (kvHolder.type == KeyValueHolderType_Offset) {
            totalSize += kvHolder.pbKeyValueSize + kvHolder.keySize + kvHolder.valueSize;
            smallestOffet = min(smallestOffet, kvHolder.offset);
        } else {
            vec.emplace_back(itr.first, kvHolder.toKFKVBuffer(nullptr, nullptr));
        }
    }
    if (smallestOffet > 5) {
        smallestOffet = ItemSizeHolderSize;
    }
    totalSize += smallestOffet;
    if (vec.empty()) {
        return make_pair(KFKVBuffer(), totalSize);
    }
    auto buffer = MiniPBCoder::encodeDataWithObject(vec);
    // skip the pb size of buffer
    auto sizeOfMap = CodedInputData(buffer.getPtr(), buffer.length()).readUInt32();
    totalSize += sizeOfMap;
    return make_pair(std::move(buffer), totalSize);
}
#endif

static pair<KFKVBuffer, size_t> prepareEncode(KFKVVector &&vec) {
    // make some room for placeholder
    size_t totalSize = ItemSizeHolderSize;
    auto buffer = MiniPBCoder::encodeDataWithObject(vec);
    // skip the pb size of buffer
    auto sizeOfMap = CodedInputData(buffer.getPtr(), buffer.length()).readUInt32();
    totalSize += sizeOfMap;
    return make_pair(std::move(buffer), totalSize);
}

// since we use append mode, when -[setData: forKey:] many times, space may not be enough
// try a full rewrite to make space
bool KFKV::ensureMemorySize(size_t newSize) {
    if (!isFileValid()) {
        KFKVWarning("[%s] file not valid", m_mmapID.c_str());
        return false;
    }
    if (isReadOnly()) {
        KFKVWarning("[%s] file readonly", m_mmapID.c_str());
        return false;
    }

    if (newSize >= m_output->spaceLeft() || (m_crypter ? m_dicCrypt->empty() : m_dic->empty())) {
        // remove expired keys
        if (m_enableKeyExpire) {
            filterExpiredKeys();
        }
        // try a full rewrite to make space
        auto preparedData = m_crypter ? prepareEncode(*m_dicCrypt) : prepareEncode(*m_dic);
        // dic.empty() means inserting key-value for the first time, no need to call msync()
        return expandAndWriteBack(newSize, std::move(preparedData), m_crypter ? !m_dicCrypt->empty() : !m_dic->empty());
    }
    return true;
}

bool KFKV::checkSizeLimit(size_t size, const KFKVBuffer &keyData, uint32_t originKeyLength) {
    if (m_itemSizeLimit != 0 && size > m_itemSizeLimit) {
        auto isKeyEncoded = (originKeyLength < keyData.length());
        uint8_t *keyPtr = nullptr;
        if (isKeyEncoded) {
            auto keyLen = pbRawVarint32Size(originKeyLength);
            keyPtr = (uint8_t *) keyData.getPtr() + keyLen;
        } else {
            keyPtr = (uint8_t *) keyData.getPtr();
        }
        KFKVError("[%s] itemSizeLimit %u: ignore value size %zu of key [%.*s] too large",
                  m_mmapID.c_str(), m_itemSizeLimit, size, originKeyLength, keyPtr);
        return false;
    }
    return true;
}

// try a full rewrite to make space
bool KFKV::expandAndWriteBack(size_t newSize, std::pair<kfkv::KFKVBuffer, size_t> preparedData, bool needSync) {
    auto fileSize = m_file->getFileSize();
    auto sizeOfDic = preparedData.second;
    size_t lenNeeded = sizeOfDic + Fixed32Size + newSize;
    size_t nowDicCount = m_crypter ? m_dicCrypt->size() : m_dic->size();
    size_t laterDicCount = std::max<size_t>(1, nowDicCount + 1);
    // or use <cmath> ceil()
    size_t avgItemSize = (lenNeeded + laterDicCount - 1) / laterDicCount;
    size_t futureUsage = avgItemSize * std::max<size_t>(8, laterDicCount / 2);
    // 1. no space for a full rewrite, double it
    // 2. or space is not large enough for future usage, double it to avoid frequently full rewrite
    if (lenNeeded >= fileSize || (needSync && (lenNeeded + futureUsage) >= fileSize)) {
        size_t oldSize = fileSize;
        do {
            fileSize *= 2;
        } while (lenNeeded + futureUsage >= fileSize);
        KFKVInfo("extending [%s] file size from %zu to %zu, incoming size:%zu, future usage:%zu", m_mmapID.c_str(),
                 oldSize, fileSize, newSize, futureUsage);

        // if we can't extend size, rollback to old state
        // this is a good place to mock enlarging file failure
        if (!m_file->truncate(fileSize)) {
            return false;
        }

        // check if we fail to make more space
        if (!isFileValid()) {
            KFKVWarning("[%s] file not valid", m_mmapID.c_str());
            return false;
        }
    }
    return doFullWriteBack(std::move(preparedData), nullptr, needSync);
}

size_t KFKV::readActualSize() {
    if (m_metaInfo->m_version >= KFKVVersionActualSize) {
        KFKV_ASSERT(m_metaFile->isFileValid());

        return m_metaInfo->m_actualSize;
    } else {
        KFKV_ASSERT(m_file->isFileValid());

        uint32_t actualSize = 0;
        memcpy(&actualSize, m_file->getMemory(), Fixed32Size);
        return actualSize;
    }
}

void KFKV::oldStyleWriteActualSize(size_t actualSize) {
    KFKV_ASSERT(m_file->getMemory());

    m_actualSize = actualSize;
    memcpy(m_file->getMemory(), &actualSize, Fixed32Size);
}

bool KFKV::writeActualSize(size_t size, uint32_t crcDigest, const void *iv, bool increaseSequence) {
    if (isReadOnly()) {
        return false;
    }

    // backward compatibility
    if (!increaseSequence && m_metaInfo->m_version < KFKVVersionActualSize) {
        oldStyleWriteActualSize(size);
    }

    if (!m_metaFile->isFileValid()) {
        return false;
    }

    bool needsFullWrite = false;
    m_actualSize = size;
    m_metaInfo->m_actualSize = static_cast<uint32_t>(size);
    m_crcDigest = crcDigest;
    m_metaInfo->m_crcDigest = crcDigest;
    if (m_metaInfo->m_version < KFKVVersionSequence) {
        m_metaInfo->m_version = KFKVVersionSequence;
        needsFullWrite = true;
    }
#ifndef KFKV_DISABLE_CRYPT
    if (kfkv_unlikely(iv)) {
        memcpy(m_metaInfo->m_vector, iv, sizeof(m_metaInfo->m_vector));
        if (m_metaInfo->m_version < KFKVVersionRandomIV) {
            m_metaInfo->m_version = KFKVVersionRandomIV;
        }
        needsFullWrite = true;
    }
#endif
    if (kfkv_unlikely(increaseSequence)) {
        m_metaInfo->m_sequence++;
        m_metaInfo->m_lastConfirmedMetaInfo.lastActualSize = static_cast<uint32_t>(size);
        m_metaInfo->m_lastConfirmedMetaInfo.lastCRCDigest = crcDigest;
        if (m_metaInfo->m_version < KFKVVersionActualSize) {
            m_metaInfo->m_version = KFKVVersionActualSize;
        }
        needsFullWrite = true;
        KFKVInfo("[%s] increase sequence to %u, crc %u, actualSize %u", m_mmapID.c_str(), m_metaInfo->m_sequence,
                 m_metaInfo->m_crcDigest, m_metaInfo->m_actualSize);
    }
    if (m_metaInfo->m_version < KFKVVersionFlag) {
        m_metaInfo->m_flags = 0;
        m_metaInfo->m_version = KFKVVersionFlag;
        needsFullWrite = true;
    }
    if (kfkv_unlikely(needsFullWrite)) {
        m_metaInfo->write(m_metaFile->getMemory());
    } else {
        m_metaInfo->writeCRCAndActualSizeOnly(m_metaFile->getMemory());
    }
    return true;
}

KFKVBuffer KFKV::getRawDataForKey(KFKVKey_t key) {
    checkLoadData();
#ifndef KFKV_DISABLE_CRYPT
    if (m_crypter) {
        auto itr = m_dicCrypt->find(key);
        if (itr != m_dicCrypt->end()) {
            auto basePtr = (uint8_t *) (m_file->getMemory()) + Fixed32Size;
            return itr->second.toKFKVBuffer(basePtr, m_crypter);
        }
    } else
#endif
    {
        auto itr = m_dic->find(key);
        if (itr != m_dic->end()) {
            auto basePtr = (uint8_t *) (m_file->getMemory()) + Fixed32Size;
            return itr->second.toKFKVBuffer(basePtr);
        }
    }
    KFKVBuffer nan;
    return nan;
}

kfkv::KFKVBuffer KFKV::getDataForKey(KFKVKey_t key) {
    if (kfkv_unlikely(m_enableKeyExpire)) {
        return getDataWithoutMTimeForKey(key);
    }
    return getRawDataForKey(key);
}

#ifndef KFKV_DISABLE_CRYPT
// for Apple watch simulator
#    if defined(TARGET_OS_SIMULATOR) && defined(TARGET_CPU_X86)
static AESCryptStatus t_status;
#    else
thread_local AESCryptStatus t_status;
#    endif
#endif // KFKV_DISABLE_CRYPT

bool KFKV::setDataForKey(KFKVBuffer &&data, KFKVKey_t key, bool isDataHolder) {
    if ((!isDataHolder && data.length() == 0) || isKeyEmpty(key)) {
        return false;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_exclusiveProcessLock);
    checkLoadData();

#ifndef KFKV_DISABLE_CRYPT
    if (m_crypter) {
        if (isDataHolder) {
            auto sizeNeededForData = pbRawVarint32Size((uint32_t) data.length()) + data.length();
            if (!KeyValueHolderCrypt::isValueStoredAsOffset(sizeNeededForData)) {
                data = MiniPBCoder::encodeDataWithObject(data);
                isDataHolder = false;
            }
        }
        auto itr = m_dicCrypt->find(key);
        if (itr != m_dicCrypt->end()) {
            bool onlyOneKey = !isMultiProcess() && m_dicCrypt->size() == 1;
#    ifdef KFKV_APPLE
            KVHolderRet_t ret;
            if (onlyOneKey) {
                ret = overrideDataWithKey(data, key, itr->second, isDataHolder);
            } else {
                ret = appendDataWithKey(data, key, itr->second, isDataHolder);
            }
#    else
            KVHolderRet_t ret;
            if (onlyOneKey) {
                ret = overrideDataWithKey(data, key, isDataHolder);
            } else {
                ret = appendDataWithKey(data, key, isDataHolder);
            }
#    endif
            if (!ret.first) {
                return false;
            }
            KeyValueHolderCrypt kvHolder;
            if (KeyValueHolderCrypt::isValueStoredAsOffset(ret.second.valueSize)) {
                kvHolder = KeyValueHolderCrypt(ret.second.keySize, ret.second.valueSize, ret.second.offset);
                memcpy(&kvHolder.cryptStatus, &t_status, sizeof(t_status));
            } else {
                kvHolder = KeyValueHolderCrypt(std::move(data));
            }
            if (kfkv_likely(!m_enableKeyExpire)) {
                itr->second = std::move(kvHolder);
            } else {
                itr = m_dicCrypt->find(key);
                if (itr != m_dicCrypt->end()) {
                    itr->second = std::move(kvHolder);
                } else {
                    // in case filterExpiredKeys() is triggered
                    m_dicCrypt->emplace(key, std::move(kvHolder));
                    kfkv_retain_key(key);
                }
            }
        } else {
            bool needOverride = !isMultiProcess() && m_dicCrypt->empty() && m_actualSize > 0;
            KVHolderRet_t ret;
            if (needOverride) {
                ret = overrideDataWithKey(data, key, isDataHolder);
            } else {
                ret = appendDataWithKey(data, key, isDataHolder);
            }
            if (!ret.first) {
                return false;
            }
            if (KeyValueHolderCrypt::isValueStoredAsOffset(ret.second.valueSize)) {
                auto r = m_dicCrypt->emplace(
                    key, KeyValueHolderCrypt(ret.second.keySize, ret.second.valueSize, ret.second.offset));
                if (r.second) {
                    memcpy(&(r.first->second.cryptStatus), &t_status, sizeof(t_status));
                }
            } else {
                m_dicCrypt->emplace(key, KeyValueHolderCrypt(std::move(data)));
            }
            kfkv_retain_key(key);
        }
    } else
#endif // KFKV_DISABLE_CRYPT
    {
        auto itr = m_dic->find(key);
        if (itr != m_dic->end()) {
            // compare data before appending to file
            if (isCompareBeforeSetEnabled()) {
                auto basePtr = (uint8_t *) (m_file->getMemory()) + Fixed32Size;
                KFKVBuffer oldValueData = itr->second.toKFKVBuffer(basePtr);
                if (isDataHolder) {
                    CodedInputData inputData(oldValueData.getPtr(), oldValueData.length());
                    try {
                        // read extra holder header bytes and to real KFKVBuffer
                        oldValueData = CodedInputData::readRealData(oldValueData);
                        if (oldValueData == data) {
                            // KFKVInfo("[key] %s, set the same data", key.c_str());
                            return true;
                        }
                    } catch (std::exception &exception) {
                        KFKVWarning("compareBeforeSet exception: %s", exception.what());
                    } catch (...) {
                        KFKVWarning("compareBeforeSet fail");
                    }
                } else {
                    if (oldValueData == data) {
                        //  KFKVInfo("[key] %s, set the same data", key.c_str());
                        return true;
                    }
                }
            }

            bool onlyOneKey = !isMultiProcess() && m_dic->size() == 1;
            if (kfkv_likely(!m_enableKeyExpire)) {
                KVHolderRet_t ret;
                if (onlyOneKey) {
                    ret = overrideDataWithKey(data, itr->second, isDataHolder);
                } else {
                    ret = appendDataWithKey(data, itr->second, isDataHolder);
                }
                if (!ret.first) {
                    return false;
                }
                itr->second = std::move(ret.second);
            } else {
                KVHolderRet_t ret;
                if (onlyOneKey) {
                    ret = overrideDataWithKey(data, key, isDataHolder);
                } else {
                    ret = appendDataWithKey(data, key, isDataHolder);
                }
                if (!ret.first) {
                    return false;
                }
                itr = m_dic->find(key);
                if (itr != m_dic->end()) {
                    itr->second = std::move(ret.second);
                } else {
                    // in case filterExpiredKeys() is triggered
                    m_dic->emplace(key, std::move(ret.second));
                    kfkv_retain_key(key);
                }
            }
        } else {
            bool needOverride = !isMultiProcess() && m_dic->empty() && m_actualSize > 0;
            KVHolderRet_t ret;
            if (needOverride) {
                ret = overrideDataWithKey(data, key, isDataHolder);
            } else {
                ret = appendDataWithKey(data, key, isDataHolder);
            }
            if (!ret.first) {
                return false;
            }
            m_dic->emplace(key, std::move(ret.second));
            kfkv_retain_key(key);
        }
    }
    m_hasFullWriteback = false;
    return true;
}

template <typename T>
static void eraseHelper(T& container, std::string_view key) {
    auto itr = container.find(key);
    if (itr != container.end()) {
        container.erase(itr);
    }
}

bool KFKV::removeDataForKey(KFKVKey_t key) {
    if (isKeyEmpty(key)) {
        return false;
    }
#ifndef KFKV_DISABLE_CRYPT
    if (m_crypter) {
        auto itr = m_dicCrypt->find(key);
        if (itr != m_dicCrypt->end()) {
            m_hasFullWriteback = false;
            static KFKVBuffer nan;
#    ifdef KFKV_APPLE
            auto ret = appendDataWithKey(nan, key, itr->second);
            if (ret.first) {
                if (kfkv_unlikely(m_enableKeyExpire)) {
                    // filterExpiredKeys() may invalid itr
                    itr = m_dicCrypt->find(key);
                    if (itr == m_dicCrypt->end()) {
                        return true;
                    }
                }
                auto oldKey = itr->first;
                m_dicCrypt->erase(itr);
                
            }
#    else
            auto ret = appendDataWithKey(nan, key);
            if (ret.first) {
                if (kfkv_unlikely(m_enableKeyExpire)) {
                    eraseHelper(*m_dicCrypt, key);
                } else {
                    m_dicCrypt->erase(itr);
                }
            }
#    endif
            return ret.first;
        }
    } else
#endif // KFKV_DISABLE_CRYPT
    {
        auto itr = m_dic->find(key);
        if (itr != m_dic->end()) {
            m_hasFullWriteback = false;
            static KFKVBuffer nan;
            auto ret = kfkv_likely(!m_enableKeyExpire) ? appendDataWithKey(nan, itr->second) : appendDataWithKey(nan, key);
            if (ret.first) {
#ifdef KFKV_APPLE
                if (kfkv_unlikely(m_enableKeyExpire)) {
                    // filterExpiredKeys() may invalid itr
                    itr = m_dic->find(key);
                    if (itr == m_dic->end()) {
                        return true;
                    }
                }
                auto oldKey = itr->first;
                m_dic->erase(itr);
                
#else
                if (kfkv_unlikely(m_enableKeyExpire)) {
                    // filterExpiredKeys() may invalid itr
                    eraseHelper(*m_dic, key);
                } else {
                    m_dic->erase(itr);
                }
#endif
            }
            return ret.first;
        }
    }

    return false;
}

KVHolderRet_t
KFKV::doAppendDataWithKey(const KFKVBuffer &data, const KFKVBuffer &keyData, bool isDataHolder, uint32_t originKeyLength) {
    auto isKeyEncoded = (originKeyLength < keyData.length());
    auto keyLength = static_cast<uint32_t>(keyData.length());
    auto valueLength = static_cast<uint32_t>(data.length());
    if (isDataHolder) {
        valueLength += pbRawVarint32Size(valueLength);
    }
    // size needed to encode the key
    size_t size = isKeyEncoded ? keyLength : (keyLength + pbRawVarint32Size(keyLength));
    // size needed to encode the value
    size += valueLength + pbRawVarint32Size(valueLength);

    SCOPED_LOCK(m_exclusiveProcessLock);

    if (!checkSizeLimit(size, keyData, originKeyLength)) {
        return make_pair(false, KeyValueHolder());
    }
    bool hasEnoughSize = ensureMemorySize(size);
    if (!hasEnoughSize || !isFileValid()) {
        return make_pair(false, KeyValueHolder());
    }

#ifndef KFKV_DISABLE_CRYPT
    if (m_crypter) {
        if (KeyValueHolderCrypt::isValueStoredAsOffset(valueLength)) {
            m_crypter->getCurStatus(t_status);
        }
    }
#endif
    try {
        if (isKeyEncoded) {
            m_output->writeRawData(keyData);
        } else {
            m_output->writeData(keyData);
        }
        if (isDataHolder) {
            m_output->writeRawVarint32((int32_t) valueLength);
        }
        m_output->writeData(data); // note: write size of data
    } catch (std::exception &e) {
        KFKVError("%s", e.what());
        return make_pair(false, KeyValueHolder());
    } catch (...) {
        KFKVError("append fail");
        return make_pair(false, KeyValueHolder());
    }

    auto offset = static_cast<uint32_t>(m_actualSize);
    auto ptr = (uint8_t *) m_file->getMemory() + Fixed32Size + m_actualSize;
#ifndef KFKV_DISABLE_CRYPT
    if (m_crypter) {
        m_crypter->encrypt(ptr, ptr, size);
    }
#endif
    m_actualSize += size;
    updateCRCDigest(ptr, size);

    return make_pair(true, KeyValueHolder(originKeyLength, valueLength, offset));
}

KVHolderRet_t KFKV::doOverrideDataWithKey(const KFKVBuffer &data,
                                          const KFKVBuffer &keyData,
                                          bool isDataHolder,
                                          uint32_t originKeyLength) {
    auto isKeyEncoded = (originKeyLength < keyData.length());
    auto keyLength = static_cast<uint32_t>(keyData.length());
    auto valueLength = static_cast<uint32_t>(data.length());
    if (isDataHolder) {
        valueLength += pbRawVarint32Size(valueLength);
    }
    // size needed to encode the key
    size_t size = isKeyEncoded ? keyLength : (keyLength + pbRawVarint32Size(keyLength));
    // size needed to encode the value
    size += valueLength + pbRawVarint32Size(valueLength);

    if (!checkSizeLimit(size, keyData, originKeyLength)) {
        return make_pair(false, KeyValueHolder());
    }

    if (!checkSizeForOverride(size)) {
        return doAppendDataWithKey(data, keyData, isDataHolder, originKeyLength);
    }

    // we don't not support override in multi-process mode
    // SCOPED_LOCK(m_exclusiveProcessLock);

#ifndef KFKV_DISABLE_CRYPT
    if (m_crypter) {
        if (m_metaInfo->m_version >= KFKVVersionRandomIV) {
            m_crypter->resetIV(m_metaInfo->m_vector, sizeof(m_metaInfo->m_vector));
        } else {
            m_crypter->resetIV();
        }
    }
#endif
    try {
        // write ItemSizeHolder
        m_output->setPosition(0);
        m_output->writeUInt32(AESCrypt::randomItemSizeHolder(ItemSizeHolderSize));
        m_actualSize = ItemSizeHolderSize;
#ifndef KFKV_DISABLE_CRYPT
        if (m_crypter) {
            auto ptr = (uint8_t *) m_file->getMemory() + Fixed32Size;
            m_crypter->encrypt(ptr, ptr, m_actualSize);
            if (KeyValueHolderCrypt::isValueStoredAsOffset(valueLength)) {
                m_crypter->getCurStatus(t_status);
            }
        }
#endif
        if (isKeyEncoded) {
            m_output->writeRawData(keyData);
        } else {
            m_output->writeData(keyData);
        }
        if (isDataHolder) {
            m_output->writeRawVarint32((int32_t) valueLength);
        }
        m_output->writeData(data); // note: write size of data
    } catch (std::exception &e) {
        KFKVError("%s", e.what());
        return make_pair(false, KeyValueHolder());
    } catch (...) {
        KFKVError("append fail");
        return make_pair(false, KeyValueHolder());
    }

    auto offset = static_cast<uint32_t>(m_actualSize);
    m_actualSize += size;
#ifndef KFKV_DISABLE_CRYPT
    if (m_crypter) {
        auto ptr = (uint8_t *) m_file->getMemory() + Fixed32Size + offset;
        m_crypter->encrypt(ptr, ptr, size);
    }
#endif
    recalculateCRCDigestOnly();

    return make_pair(true, KeyValueHolder(originKeyLength, valueLength, offset));
}

bool KFKV::checkSizeForOverride(size_t size) {
    if (!isFileValid()) {
        KFKVWarning("[%s] file not valid", m_mmapID.c_str());
        return false;
    }

    // only override if the file can hole it without ftruncate()
    auto fileSize = m_file->getFileSize();
    auto spaceNeededForOverride = size + Fixed32Size + ItemSizeHolderSize;
    if (size > fileSize || spaceNeededForOverride > fileSize) {
        return false;
    }
    return true;
}

KVHolderRet_t KFKV::appendDataWithKey(const KFKVBuffer &data, KFKVKey_t key, bool isDataHolder) {
#ifdef KFKV_APPLE
    auto oData = [key dataUsingEncoding:NSUTF8StringEncoding];
    auto keyData = KFKVBuffer(oData, KFKVBufferNoCopy);
#else
    auto keyData = KFKVBuffer((void *) key.data(), key.size(), KFKVBufferNoCopy);
#endif
    return doAppendDataWithKey(data, keyData, isDataHolder, static_cast<uint32_t>(keyData.length()));
}

KVHolderRet_t KFKV::overrideDataWithKey(const KFKVBuffer &data, KFKVKey_t key, bool isDataHolder) {
#ifdef KFKV_APPLE
    auto oData = [key dataUsingEncoding:NSUTF8StringEncoding];
    auto keyData = KFKVBuffer(oData, KFKVBufferNoCopy);
#else
    auto keyData = KFKVBuffer((void *) key.data(), key.size(), KFKVBufferNoCopy);
#endif
    return doOverrideDataWithKey(data, keyData, isDataHolder, static_cast<uint32_t>(keyData.length()));
}

KVHolderRet_t KFKV::appendDataWithKey(const KFKVBuffer &data, const KeyValueHolder &kvHolder, bool isDataHolder) {
    SCOPED_LOCK(m_exclusiveProcessLock);

    uint32_t keyLength = kvHolder.keySize;
    // size needed to encode the key
    size_t rawKeySize = keyLength + pbRawVarint32Size(keyLength);

    // ensureMemorySize() might change kvHolder.offset, so have to do it early
    {
        auto valueLength = static_cast<uint32_t>(data.length());
        if (isDataHolder) {
            valueLength += pbRawVarint32Size(valueLength);
        }
        auto size = rawKeySize + valueLength + pbRawVarint32Size(valueLength);
        bool hasEnoughSize = ensureMemorySize(size);
        if (!hasEnoughSize) {
            return make_pair(false, KeyValueHolder());
        }
    }
    auto basePtr = (uint8_t *) m_file->getMemory() + Fixed32Size;
    KFKVBuffer keyData(basePtr + kvHolder.offset, rawKeySize, KFKVBufferNoCopy);

    return doAppendDataWithKey(data, keyData, isDataHolder, keyLength);
}

// only one key in dict, do not append, just rewrite from beginning
KVHolderRet_t KFKV::overrideDataWithKey(const KFKVBuffer &data, const KeyValueHolder &kvHolder, bool isDataHolder) {
    // we don't not support override in multi-process mode
    // SCOPED_LOCK(m_exclusiveProcessLock);

    uint32_t keyLength = kvHolder.keySize;
    // size needed to encode the key
    size_t rawKeySize = keyLength + pbRawVarint32Size(keyLength);

    // ensureMemorySize() (inside doAppendDataWithKey() which be called from doOverrideDataWithKey())
    // might change kvHolder.offset, so have to do it early
    {
        auto valueLength = static_cast<uint32_t>(data.length());
        if (isDataHolder) {
            valueLength += pbRawVarint32Size(valueLength);
        }
        auto size = rawKeySize + valueLength + pbRawVarint32Size(valueLength);
        bool hasEnoughSize = checkSizeForOverride(size);
        if (!hasEnoughSize) {
            return appendDataWithKey(data, kvHolder, isDataHolder);
        }
    }
    auto basePtr = (uint8_t *) m_file->getMemory() + Fixed32Size;
    KFKVBuffer keyData;
    if (kvHolder.offset < ItemSizeHolderSize) {
        keyData = KFKVBuffer(basePtr + kvHolder.offset, rawKeySize, KFKVBufferCopy);
    } else {
        keyData = KFKVBuffer(basePtr + kvHolder.offset, rawKeySize, KFKVBufferNoCopy);
    }

    return doOverrideDataWithKey(data, keyData, isDataHolder, keyLength);
}

bool KFKV::fullWriteback(AESCrypt *newCrypter, bool onlyWhileExpire) {
    if (m_hasFullWriteback) {
        return true;
    }
    if (m_needLoadFromFile) {
        return true;
    }
    if (!isFileValid()) {
        KFKVWarning("[%s] file not valid", m_mmapID.c_str());
        return false;
    }
    if (isReadOnly()) {
        KFKVWarning("[%s] file readonly", m_mmapID.c_str());
        return false;
    }

    if (kfkv_unlikely(m_enableKeyExpire)) {
        auto expiredCount = filterExpiredKeys();
        if (onlyWhileExpire && expiredCount == 0) {
            return true;
        }
    }

    auto isEmpty = m_crypter ? m_dicCrypt->empty() : m_dic->empty();
    if (isEmpty) {
        clearAll();
        return true;
    }

    SCOPED_LOCK(m_exclusiveProcessLock);
    auto preparedData = m_crypter ? prepareEncode(*m_dicCrypt) : prepareEncode(*m_dic);
    auto sizeOfDic = preparedData.second;
    if (sizeOfDic > 0) {
        auto fileSize = m_file->getFileSize();
        if (sizeOfDic + Fixed32Size <= fileSize) {
            return doFullWriteBack(std::move(preparedData), newCrypter);
        } else {
            assert(0);
            assert(newCrypter == nullptr);
            // expandAndWriteBack() will extend file & full rewrite, no need to write back again
            auto newSize = sizeOfDic + Fixed32Size - fileSize;
            return expandAndWriteBack(newSize, std::move(preparedData));
        }
    }
    return false;
}

// we don't need to really serialize the dictionary, just reuse what's already in the file
static void
memmoveDictionary(KFKVMap &dic, CodedOutputData *output, uint8_t *ptr, AESCrypt *encrypter, size_t totalSize) {
    auto originOutputPtr = output->curWritePointer();
    // make space to hold the fake size of dictionary's serialization result
    auto writePtr = originOutputPtr + ItemSizeHolderSize;
    // reuse what's already in the file
    if (!dic.empty()) {
        // sort by offset
        vector<KeyValueHolder *> vec;
        vec.reserve(dic.size());
        for (auto &itr : dic) {
            vec.push_back(&itr.second);
        }
        sort(vec.begin(), vec.end(), [](const auto &left, const auto &right) { return left->offset < right->offset; });

        // merge nearby items to make memmove quicker
        vector<pair<uint32_t, uint32_t>> dataSections; // pair(offset, size)
        dataSections.emplace_back(vec.front()->offset, vec.front()->computedKVSize + vec.front()->valueSize);
        for (size_t index = 1, total = vec.size(); index < total; index++) {
            auto kvHolder = vec[index];
            auto &lastSection = dataSections.back();
            if (kvHolder->offset == lastSection.first + lastSection.second) {
                lastSection.second += kvHolder->computedKVSize + kvHolder->valueSize;
            } else {
                dataSections.emplace_back(kvHolder->offset, kvHolder->computedKVSize + kvHolder->valueSize);
            }
        }
        // do the move
        auto basePtr = ptr + Fixed32Size;
        for (auto &section : dataSections) {
            // memmove() should handle this well: src == dst
            memmove(writePtr, basePtr + section.first, section.second);
            writePtr += section.second;
        }
        // update offset
        if (!encrypter) {
            auto offset = ItemSizeHolderSize;
            for (auto kvHolder : vec) {
                kvHolder->offset = offset;
                offset += kvHolder->computedKVSize + kvHolder->valueSize;
            }
        }
    }
    // hold the fake size of dictionary's serialization result
    output->writeUInt32(AESCrypt::randomItemSizeHolder(ItemSizeHolderSize));
    auto writtenSize = static_cast<size_t>(writePtr - originOutputPtr);
#ifndef KFKV_DISABLE_CRYPT
    if (encrypter) {
        encrypter->encrypt(originOutputPtr, originOutputPtr, writtenSize);
    }
#endif
    assert(writtenSize == totalSize);
    output->seek(writtenSize - ItemSizeHolderSize);
}

#ifndef KFKV_DISABLE_CRYPT

static void memmoveDictionary(KFKVMapCrypt &dic,
                              CodedOutputData *output,
                              uint8_t *ptr,
                              AESCrypt *decrypter,
                              AESCrypt *encrypter,
                              pair<KFKVBuffer, size_t> &preparedData) {
    // reuse what's already in the file
    vector<KeyValueHolderCrypt *> vec;
    if (!dic.empty()) {
        // sort by offset
        vec.reserve(dic.size());
        for (auto &itr : dic) {
            if (itr.second.type == KeyValueHolderType_Offset) {
                vec.push_back(&itr.second);
            }
        }
        sort(vec.begin(), vec.end(), [](auto left, auto right) { return left->offset < right->offset; });
    }
    auto sizeHolderSize = ItemSizeHolderSize;
    auto sizeHolder = AESCrypt::randomItemSizeHolder(sizeHolderSize);
    if (!vec.empty()) {
        auto smallestOffset = vec.front()->offset;
        if (smallestOffset != ItemSizeHolderSize && smallestOffset <= 5) {
            sizeHolderSize = smallestOffset;
            assert(sizeHolderSize != 0);
            static const uint32_t ItemSizeHolders[] = {0, 0x0f, 0xff, 0xffff, 0xffffff, 0xffffffff};
            sizeHolder = AESCrypt::randomItemSizeHolder(sizeHolderSize);
            assert(sizeHolder >= ItemSizeHolders[sizeHolderSize] && sizeHolder <= ItemSizeHolders[sizeHolderSize]);
        }
    }
    output->writeRawVarint32(static_cast<int32_t>(sizeHolder));
    auto writePtr = output->curWritePointer();
    if (encrypter) {
        encrypter->encrypt(writePtr - sizeHolderSize, writePtr - sizeHolderSize, sizeHolderSize);
    }
    if (!vec.empty()) {
        // merge nearby items to make memmove quicker
        vector<tuple<uint32_t, uint32_t, AESCryptStatus *>> dataSections; // pair(offset, size)
        dataSections.push_back(vec.front()->toTuple());
        for (size_t index = 1, total = vec.size(); index < total; index++) {
            auto kvHolder = vec[index];
            auto &lastSection = dataSections.back();
            if (kvHolder->offset == get<0>(lastSection) + get<1>(lastSection)) {
                get<1>(lastSection) += kvHolder->pbKeyValueSize + kvHolder->keySize + kvHolder->valueSize;
            } else {
                dataSections.push_back(kvHolder->toTuple());
            }
        }
        // do the move
        auto basePtr = ptr + Fixed32Size;
        for (auto &section : dataSections) {
            auto crypter = decrypter->cloneWithStatus(*get<2>(section));
            crypter.decrypt(basePtr + get<0>(section), writePtr, get<1>(section));
            writePtr += get<1>(section);
        }
        // update offset & AESCryptStatus
        if (encrypter) {
            auto offset = sizeHolderSize;
            for (auto kvHolder : vec) {
                kvHolder->offset = offset;
                auto size = kvHolder->pbKeyValueSize + kvHolder->keySize + kvHolder->valueSize;
                encrypter->getCurStatus(kvHolder->cryptStatus);
                encrypter->encrypt(basePtr + offset, basePtr + offset, size);
                offset += size;
            }
        }
    }
    auto &data = preparedData.first;
    if (data.length() > 0) {
        auto dataSize = CodedInputData(data.getPtr(), data.length()).readUInt32();
        if (dataSize > 0) {
            auto dataPtr = (uint8_t *) data.getPtr() + pbRawVarint32Size(dataSize);
            if (encrypter) {
                encrypter->encrypt(dataPtr, writePtr, dataSize);
            } else {
                memcpy(writePtr, dataPtr, dataSize);
            }
            writePtr += dataSize;
        }
    }
    auto writtenSize = static_cast<size_t>(writePtr - output->curWritePointer());
    assert(writtenSize + sizeHolderSize == preparedData.second);
    output->seek(writtenSize);
}

#    define InvalidCryptPtr ((AESCrypt *) (void *) (1))

#endif // KFKV_DISABLE_CRYPT

static void fullWriteBackWholeData(KFKVBuffer allData, size_t totalSize, CodedOutputData *output) {
    auto originOutputPtr = output->curWritePointer();
    output->writeUInt32(AESCrypt::randomItemSizeHolder(ItemSizeHolderSize));
    if (allData.length() > 0) {
        auto dataSize = CodedInputData(allData.getPtr(), allData.length()).readUInt32();
        if (dataSize > 0) {
            auto dataPtr = (uint8_t *) allData.getPtr() + pbRawVarint32Size(dataSize);
            memcpy(output->curWritePointer(), dataPtr, dataSize);
            output->seek(dataSize);
        }
    }
    [[maybe_unused]] auto writtenSize = (size_t)(output->curWritePointer() - originOutputPtr);
    assert(writtenSize == totalSize);
}

#ifndef KFKV_DISABLE_CRYPT
bool KFKV::doFullWriteBack(pair<KFKVBuffer, size_t> prepared, AESCrypt *newCrypter, bool needSync) {
    auto ptr = (uint8_t *) m_file->getMemory();
    auto totalSize = prepared.second;

    uint8_t newIV[AES_IV_LEN];
    auto encrypter = (newCrypter == InvalidCryptPtr) ? nullptr : (newCrypter ? newCrypter : m_crypter);
    if (encrypter) {
        AESCrypt::fillRandomIV(newIV);
        encrypter->resetIV(newIV, sizeof(newIV));
    }

    delete m_output;
    m_output = new CodedOutputData(ptr + Fixed32Size, m_file->getFileSize() - Fixed32Size);
    if (m_crypter) {
        auto decrypter = m_crypter;
        memmoveDictionary(*m_dicCrypt, m_output, ptr, decrypter, encrypter, prepared);
    } else if (prepared.first.length() != 0) {
        auto &preparedData = prepared.first;
        fullWriteBackWholeData(std::move(preparedData), totalSize, m_output);
        if (encrypter) {
            encrypter->encrypt(ptr + Fixed32Size, ptr + Fixed32Size, totalSize);
        }
    } else {
        memmoveDictionary(*m_dic, m_output, ptr, encrypter, totalSize);
    }

    m_actualSize = totalSize;
    if (encrypter) {
        recalculateCRCDigestWithIV(newIV);
    } else {
        recalculateCRCDigestWithIV(nullptr);
    }
    m_hasFullWriteback = true;
    // make sure lastConfirmedMetaInfo is saved if needed
    if (needSync) {
        sync(KFKV_SYNC);
    }
    return true;
}

#else // KFKV_DISABLE_CRYPT

bool KFKV::doFullWriteBack(pair<KFKVBuffer, size_t> prepared, AESCrypt *, bool needSync) {
    auto ptr = (uint8_t *) m_file->getMemory();
    auto totalSize = prepared.second;

    delete m_output;
    m_output = new CodedOutputData(ptr + Fixed32Size, m_file->getFileSize() - Fixed32Size);
    if (prepared.first.length() != 0) {
        auto &preparedData = prepared.first;
        fullWriteBackWholeData(std::move(preparedData), totalSize, m_output);
    } else {
        constexpr AESCrypt *encrypter = nullptr;
        memmoveDictionary(*m_dic, m_output, ptr, encrypter, totalSize);
    }

    m_actualSize = totalSize;
    recalculateCRCDigestWithIV(nullptr);
    m_hasFullWriteback = true;
    // make sure lastConfirmedMetaInfo is saved if needed
    if (needSync) {
        sync(KFKV_SYNC);
    }
    return true;
}
#endif // KFKV_DISABLE_CRYPT

#ifndef KFKV_DISABLE_CRYPT
bool KFKV::reKey(const string &cryptKey, bool aes256) {
    if (isReadOnly()) {
        KFKVWarning("[%s] file readonly", m_mmapID.c_str());
        return false;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_exclusiveProcessLock);
    checkLoadData();
    if (!isFileValid()) {
        KFKVWarning("[%s] file not valid", m_mmapID.c_str());
        return false;
    }

    bool ret = false;
    if (m_crypter) {
        if (cryptKey.length() > 0) {
            string oldKey = this->cryptKey();
            if (cryptKey == oldKey) {
                return true;
            } else {
                // change encryption key
                KFKVInfo("reKey with new aes key");
                auto newCrypt = new AESCrypt(cryptKey.data(), cryptKey.length(), nullptr, 0, aes256);
                m_hasFullWriteback = false;
                ret = fullWriteback(newCrypt);
                if (ret) {
                    delete m_crypter;
                    m_crypter = newCrypt;
                } else {
                    delete newCrypt;
                }
            }
        } else {
            // decryption to plain text
            KFKVInfo("reKey to no aes key");
            m_hasFullWriteback = false;
            ret = fullWriteback(InvalidCryptPtr);
            if (ret) {
                delete m_crypter;
                m_crypter = nullptr;
                if (!m_dic) {
                    m_dic = new KFKVMap();
                }
            }
        }
    } else {
        if (cryptKey.length() > 0) {
            // transform plain text to encrypted text
            KFKVInfo("reKey to a aes key");
            m_hasFullWriteback = false;
            auto newCrypt = new AESCrypt(cryptKey.data(), cryptKey.length(), nullptr, 0, aes256);
            ret = fullWriteback(newCrypt);
            if (ret) {
                m_crypter = newCrypt;
                if (!m_dicCrypt) {
                    m_dicCrypt = new KFKVMapCrypt();
                }
            } else {
                delete newCrypt;
            }
        } else {
            return true;
        }
    }
    // m_dic or m_dicCrypt is not valid after reKey
    if (ret) {
        clearMemoryCache();
    }
    return ret;
}
#endif

void KFKV::trim() {
    KFKVInfo("prepare to trim %s", m_mmapID.c_str());
    if (isReadOnly()) {
        KFKVWarning("[%s] file readonly", m_mmapID.c_str());
        return;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_exclusiveProcessLock);
    checkLoadData();
    if (!isFileValid()) {
        KFKVWarning("[%s] file not valid", m_mmapID.c_str());
        return;
    }

    if (m_actualSize == 0) {
        clearAll();
        return;
    } else if (m_file->getFileSize() <= m_expectedCapacity) {
        return;
    }

    fullWriteback();
    auto oldSize = m_file->getFileSize();
    auto fileSize = oldSize;
    while (fileSize > (m_actualSize + Fixed32Size) * 2) {
        fileSize /= 2;
    }
    fileSize = std::max<size_t>(fileSize, m_expectedCapacity);
    if (oldSize == fileSize) {
        KFKVInfo("there's no need to trim %s with size %zu, actualSize %zu", m_mmapID.c_str(), fileSize, m_actualSize);
        return;
    }

    KFKVInfo("trimming %s from %zu to %zu, actualSize %zu", m_mmapID.c_str(), oldSize, fileSize, m_actualSize);

    if (!m_file->truncate(fileSize)) {
        return;
    }
    fileSize = m_file->getFileSize();
    auto ptr = (uint8_t *) m_file->getMemory();
    delete m_output;
    m_output = new CodedOutputData(ptr + pbFixed32Size(), fileSize - Fixed32Size);
    m_output->seek(m_actualSize);

    KFKVInfo("finish trim %s from %zu to %zu", m_mmapID.c_str(), oldSize, fileSize);
}

void KFKV::clearAll(bool keepSpace) {
    KFKVInfo("cleaning all key-values from [%s]", m_mmapID.c_str());
    if (isReadOnly()) {
        KFKVWarning("[%s] file readonly", m_mmapID.c_str());
        return;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_exclusiveProcessLock);
    checkLoadData();
    if (!isFileValid()) {
        KFKVWarning("[%s] file not valid", m_mmapID.c_str());
        return;
    }

    if (m_file->getFileSize() == m_expectedCapacity && m_actualSize == 0) {
        KFKVInfo("nothing to clear for [%s]", m_mmapID.c_str());
        return;
    }

    if (!keepSpace) {
        m_file->truncate(m_expectedCapacity);
    }

#ifndef KFKV_DISABLE_CRYPT
    uint8_t newIV[AES_IV_LEN];
    AESCrypt::fillRandomIV(newIV);
    if (m_crypter) {
        m_crypter->resetIV(newIV, sizeof(newIV));
    }
    writeActualSize(0, 0, newIV, IncreaseSequence);
#else
    writeActualSize(0, 0, nullptr, IncreaseSequence);
#endif

    m_metaFile->msync(KFKV_SYNC);

    clearMemoryCache(keepSpace);
    loadFromFile();
}

size_t KFKV::importFrom(KFKV *src) {
    if (!src) {
        return 0;
    }
    KFKVInfo("importing from [%s] to [%s]", src->m_mmapID.c_str(), m_mmapID.c_str());
    if (isReadOnly()) {
        KFKVWarning("[%s] file readonly", m_mmapID.c_str());
        return 0;
    }

    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_exclusiveProcessLock);
    SCOPED_LOCK(src->m_lock);
    SCOPED_LOCK(src->m_exclusiveProcessLock);

    checkLoadData();
    src->checkLoadData();
    if (!isFileValid() || !src->isFileValid()) {
        KFKVWarning("[%s] or [%s] file not valid", m_mmapID.c_str(), src->m_mmapID.c_str());
        return 0;
    }

    size_t count = 0;
    bool notAutoExpire = !m_enableKeyExpire;
    auto time = UInt32ToInt32((m_expiredInSeconds != ExpireNever) ? getCurrentTimeInSecond() + m_expiredInSeconds : ExpireNever);
    for (auto &key : src->allKeys(false)) {
        auto value = src->getDataForKey(key);
        if (value.length() > 0) {
            if (kfkv_likely(notAutoExpire)) {
                setDataForKey(std::move(value), key, false);
            } else {
                auto tmp = KFKVBuffer(value.length() + Fixed32Size);
                CodedOutputData output(tmp.getPtr(), tmp.length());
                // no need write size, it's already written in value
                output.writeRawData(value);
                output.writeRawLittleEndian32(time);
                setDataForKey(std::move(tmp), key, false);
            }
            count++;
        }
    }

    KFKVInfo("imported %llu from [%s] to [%s]", count, src->m_mmapID.c_str(), m_mmapID.c_str());
    return count;
}

static std::pair<KFKVPath_t, KFKVPath_t> getStorage(const std::string &mmapID, const KFKVPath_t *relatePath, std::string& realID, std::string& mmapKey) {
    relatePath = relatePath ? relatePath : &g_realRootDir;
    auto ns = KFKV::nameSpace(*relatePath);
    relatePath = &ns.getRootDir();
#ifdef KFKV_ANDROID
    auto migrateStatus = tryMigrateLegacyKFKVFile(mmapID, relatePath, true);
    if (migrateStatus == MigrateStatus::NoneExist) {
        KFKVWarning("file id [%s] not exist in path %s", mmapID.c_str(), relatePath->c_str());
        return {};
    } else if (migrateStatus == MigrateStatus::OldToNewMigrateFail) {
        realID = legacyMmapedKVKey(mmapID, relatePath);
    } else {
        realID = mmapID;
    }
    KFKVPath_t kvPath = mappedKVPathWithID(realID, relatePath, KFKV_MULTI_PROCESS, true);
#else
    realID = mmapID;
    KFKVPath_t kvPath = mappedKVPathWithID(realID, relatePath, true);
#endif
    mmapKey = mmapedKVKey(realID, relatePath, true);
    KFKVDebug("mmapKey %s, real ID %s", mmapKey.c_str(), realID.c_str());

    KFKVPath_t crcPath = crcPathWithPath(kvPath);
    if (!isFileExist(kvPath)) {
        const auto &kvPathUTF8 = KFKVPath_t2String(kvPath);
        KFKVInfo("file not exist %s", kvPathUTF8.c_str());
        kvPath.resize(0);
    }
    if (!isFileExist(crcPath)) {
        const auto &crcPathUTF8 = KFKVPath_t2String(crcPath);
        KFKVInfo("crc file not exist %s", crcPathUTF8.c_str());
        crcPath.resize(0);
    }
    return {kvPath, crcPath};
}

bool KFKV::isFileValid(const string &mmapID, const KFKVPath_t *relatePath) {
    if (!g_instanceLock) {
        return false;
    }
    SCOPED_LOCK(g_instanceLock);

    std::string realID, mmapKey;
    auto [kvPath, crcPath] = getStorage(mmapID, relatePath, realID, mmapKey);
    if (kvPath.empty()) {
        return true;
    }
    if (crcPath.empty()) {
        return false;
    }

    uint32_t crcFile = 0;
    KFKVBuffer *data = readWholeFile(crcPath);
    if (data) {
        if (data->getPtr()) {
            KFKVMetaInfo metaInfo;
            metaInfo.read(data->getPtr());
            crcFile = metaInfo.m_crcDigest;
        }
        delete data;
    } else {
        return false;
    }

    uint32_t crcDigest = 0;
    KFKVBuffer *fileData = readWholeFile(kvPath);
    if (fileData) {
        if (fileData->getPtr() && (fileData->length() >= Fixed32Size)) {
            uint32_t actualSize = 0;
            memcpy(&actualSize, fileData->getPtr(), Fixed32Size);
            if (actualSize > (fileData->length() - Fixed32Size)) {
                delete fileData;
                return false;
            }

            crcDigest = (uint32_t) CRC32(0, (const uint8_t *) fileData->getPtr() + Fixed32Size, (uint32_t) actualSize);
        }
        delete fileData;
        return crcFile == crcDigest;
    } else {
        return false;
    }
}

bool KFKV::removeStorage(const std::string &mmapID, const KFKVPath_t *relatePath) {
    if (!g_instanceLock) {
        return false;
    }
    SCOPED_LOCK(g_instanceLock);

    std::string realID, mmapKey;
    auto [kvPath, crcPath] = getStorage(mmapID, relatePath, realID, mmapKey);
    if (kvPath.empty() && crcPath.empty()) {
        return false;
    }
    KFKVInfo("remove storage [%s]", realID.c_str());

    if (crcPath.empty()) {
        deleteFile(kvPath);
        return true;
    }

    File crcFile(crcPath, OpenFlag::ReadOnly);
    if (!crcFile.isFileValid()) {
        deleteFile(kvPath);
        return true;
    }
    FileLock fileLock(crcFile.getFd());
    InterProcessLock lock(&fileLock, ExclusiveLockType);
    SCOPED_LOCK(&lock);

    auto itr = g_instanceDic->find(mmapKey);
    if (itr != g_instanceDic->end()) {
        itr->second->close();
        // itr is not valid after this
    }

    deleteFile(kvPath);
    deleteFile(crcPath);

    return true;
}

bool KFKV::checkExist(const std::string &mmapID, const KFKVPath_t *relatePath) {
    if (!g_instanceLock) {
        return false;
    }
    SCOPED_LOCK(g_instanceLock);

    std::string realID, mmapKey;
    auto [kvPath, crcPath] = getStorage(mmapID, relatePath, realID, mmapKey);
    return (!kvPath.empty() && !crcPath.empty());
}

// ---- auto expire ----

uint32_t KFKV::getCurrentTimeInSecond() {
    auto time = ::time(nullptr);
    return static_cast<uint32_t>(time);
}

bool KFKV::doFullWriteBack(KFKVVector &&vec) {
    auto preparedData = prepareEncode(std::move(vec));

    // must clean before write-back and after prepareEncode()
    if (m_crypter) {
        clearDictionary(m_dicCrypt);
    } else {
        clearDictionary(m_dic);
    }

    bool ret = false;
    auto sizeOfDic = preparedData.second;
    auto fileSize = m_file->getFileSize();
    if (sizeOfDic + Fixed32Size <= fileSize) {
        ret = doFullWriteBack(std::move(preparedData), nullptr);
    } else {
        // expandAndWriteBack() will extend file & full rewrite, no need to write back again
        auto newSize = sizeOfDic + Fixed32Size - fileSize;
        ret = expandAndWriteBack(newSize, std::move(preparedData));
    }

    clearMemoryCache();
    return ret;
}

void KFKV::configAutoExipreIfNeeded(const KFKVConfig &config) {
    if (!config.enableKeyExpire.has_value()) {
        return;
    }
    if (isReadOnly()) {
        KFKVWarning("[%s] file readonly", m_mmapID.c_str());
        return;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_exclusiveProcessLock);

    // it will set m_enableKeyExpire from meta file
    loadMetaInfoAndCheck();

    if (!m_metaFile->isFileValid()) {
        return;
    }

    if (m_enableKeyExpire) {
        if (config.enableKeyExpire.value()) {
            m_expiredInSeconds = config.expiredInSeconds;
        } else {
            disableAutoKeyExpire();
        }
    } else {
        if (config.enableKeyExpire.value()) {
            enableAutoKeyExpire(config.expiredInSeconds);
        } else {
            // no action
        }
    }
}

bool KFKV::enableAutoKeyExpire(uint32_t expiredInSeconds) {
    if (isReadOnly()) {
        KFKVWarning("[%s] file readonly", m_mmapID.c_str());
        return false;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_exclusiveProcessLock);
    checkLoadData();
    if (!isFileValid() || !m_metaFile->isFileValid()) {
        KFKVWarning("[%s] file not valid", m_mmapID.c_str());
        return false;
    }

    if (m_enableCompareBeforeSet) {
        KFKVError("enableCompareBeforeSet will be invalid when Expiration is on");
        m_enableCompareBeforeSet = false;
    }

    if (m_expiredInSeconds != expiredInSeconds) {
        KFKVInfo("expiredInSeconds: %u", expiredInSeconds);
        m_expiredInSeconds = expiredInSeconds;
    }
    m_enableKeyExpire = true;
    if (m_metaInfo->hasFlag(KFKVMetaInfo::EnableKeyExipre)) {
        return true;
    }

    auto autoRecordExpireTime = (m_expiredInSeconds != 0);
    auto time = autoRecordExpireTime ? getCurrentTimeInSecond() + m_expiredInSeconds : 0;
    KFKVInfo("turn on recording expire date for all keys inside [%s] from now %u", m_mmapID.c_str(), time);
    m_metaInfo->setFlag(KFKVMetaInfo::EnableKeyExipre);
    m_metaInfo->m_version = KFKVVersionFlag;

    if (m_file->getFileSize() == m_expectedCapacity && m_actualSize == 0) {
        KFKVInfo("file is new, don't need a full writeback [%s], just update meta file", m_mmapID.c_str());
        writeActualSize(0, 0, nullptr, IncreaseSequence);
        m_metaFile->msync(KFKV_SYNC);
        return true;
    }

    KFKVVector vec;
    auto packKeyValue = [&](const auto &key, const KFKVBuffer &value) {
        KFKVBuffer data(value.length() + Fixed32Size);
        auto ptr = (uint8_t *) data.getPtr();
        memcpy(ptr, value.getPtr(), value.length());
        memcpy(ptr + value.length(), &time, Fixed32Size);
        vec.emplace_back(key, std::move(data));
    };

    auto basePtr = (uint8_t *) (m_file->getMemory()) + Fixed32Size;
#ifndef KFKV_DISABLE_CRYPT
    if (m_crypter) {
        for (auto &pair : *m_dicCrypt) {
            auto &key = pair.first;
            auto &value = pair.second;
            auto buffer = value.toKFKVBuffer(basePtr, m_crypter);
            packKeyValue(key, buffer);
        }
    } else
#endif
    {
        for (auto &pair : *m_dic) {
            auto &key = pair.first;
            auto &value = pair.second;
            auto buffer = value.toKFKVBuffer(basePtr);
            packKeyValue(key, buffer);
        }
    }

    return doFullWriteBack(std::move(vec));
}

bool KFKV::disableAutoKeyExpire() {
    if (isReadOnly()) {
        KFKVWarning("[%s] file readonly", m_mmapID.c_str());
        return false;
    }
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_exclusiveProcessLock);
    checkLoadData();
    if (!isFileValid() || !m_metaFile->isFileValid()) {
        KFKVWarning("[%s] file not valid", m_mmapID.c_str());
        return false;
    }

    m_expiredInSeconds = 0;
    m_enableKeyExpire = false;
    if (!m_metaInfo->hasFlag(KFKVMetaInfo::EnableKeyExipre)) {
        return true;
    }

    KFKVInfo("erase previous recorded expire date for all keys inside [%s]", m_mmapID.c_str());
    m_metaInfo->unsetFlag(KFKVMetaInfo::EnableKeyExipre);
    m_metaInfo->m_version = KFKVVersionFlag;

    if (m_file->getFileSize() == m_expectedCapacity && m_actualSize == 0) {
        KFKVInfo("file is new, don't need a full write-back [%s], just update meta file", m_mmapID.c_str());
        writeActualSize(0, 0, nullptr, IncreaseSequence);
        m_metaFile->msync(KFKV_SYNC);
        return true;
    }

    KFKVVector vec;
    auto packKeyValue = [&](auto &key, const KFKVBuffer &value) {
        assert(value.length() >= Fixed32Size);
        if (value.length() < Fixed32Size) {
#ifdef KFKV_APPLE
            KFKVWarning("key [%@] has invalid value size %u", key, value.length());
#else
            KFKVWarning("key [%s] has invalid value size %u", key.data(), value.length());
#endif
            return;
        }
        KFKVBuffer data(value.length() - Fixed32Size);
        auto ptr = (uint8_t *) data.getPtr();
        memcpy(ptr, value.getPtr(), value.length() - Fixed32Size);
        vec.emplace_back(key, std::move(data));
    };

    auto basePtr = (uint8_t *) (m_file->getMemory()) + Fixed32Size;
#ifndef KFKV_DISABLE_CRYPT
    if (m_crypter) {
        for (auto &pair : *m_dicCrypt) {
            auto &key = pair.first;
            auto &value = pair.second;
            auto buffer = value.toKFKVBuffer(basePtr, m_crypter);
            packKeyValue(key, buffer);
        }
    } else
#endif
    {
        for (auto &pair : *m_dic) {
            auto &key = pair.first;
            auto &value = pair.second;
            auto buffer = value.toKFKVBuffer(basePtr);
            packKeyValue(key, buffer);
        }
    }

    return doFullWriteBack(std::move(vec));
}

uint32_t KFKV::getExpireTimeForKey(KFKVKey_t key) {
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    checkLoadData();

    if (!m_enableKeyExpire || kfkv_key_length(key) == 0) {
        return 0;
    }
    auto raw = getRawDataForKey(key);
    assert(raw.length() == 0 || raw.length() >= Fixed32Size);
    if (raw.length() < Fixed32Size) {
        if (raw.length() != 0) {
#ifdef KFKV_APPLE
            KFKVWarning("key [%@] has invalid value size %u", key, raw.length());
#else
            KFKVWarning("key [%s] has invalid value size %u", key.data(), raw.length());
#endif
        }
        return 0;
    }
    auto ptr = (const uint8_t *) raw.getPtr() + raw.length() - Fixed32Size;
    auto time = *(const uint32_t *) ptr;
    return time;
}

kfkv::KFKVBuffer KFKV::getDataWithoutMTimeForKey(KFKVKey_t key) {
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_sharedProcessLock);
    checkLoadData();

    auto raw = getRawDataForKey(key);
    assert(raw.length() == 0 || raw.length() >= Fixed32Size);
    if (raw.length() < Fixed32Size) {
        if (raw.length() != 0) {
#ifdef KFKV_APPLE
            KFKVWarning("key [%@] has invalid value size %u", key, raw.length());
#else
            KFKVWarning("key [%s] has invalid value size %u", key.data(), raw.length());
#endif
        }
        return raw;
    }
    auto newLength = raw.length() - Fixed32Size;
    if (m_enableKeyExpire) {
        auto ptr = (const uint8_t *) raw.getPtr() + newLength;
        auto time = *(const uint32_t *) ptr;
        if (time != ExpireNever && time <= getCurrentTimeInSecond()) {
#ifdef KFKV_APPLE
            KFKVInfo("deleting expired key .+ in kfkv [%s], due date %u", key, m_mmapID.c_str(), time);
#else
            KFKVInfo("deleting expired key .+ in kfkv [%s], due date %u", key.data(), m_mmapID.c_str(), time);
#endif
            removeValueForKey(key);
            return KFKVBuffer();
        }
    }
    return KFKVBuffer(std::move(raw), newLength);
}

#define NOOP ((void) 0)

size_t KFKV::filterExpiredKeys() {
    if (!m_enableKeyExpire || (m_crypter ? m_dicCrypt->empty() : m_dic->empty())) {
        return 0;
    }
    SCOPED_LOCK(m_sharedProcessLock);

    auto now = getCurrentTimeInSecond();
    KFKVInfo("filtering expired keys inside [%s] now: %u, m_expiredInSeconds: %u", m_mmapID.c_str(), now,
             m_expiredInSeconds);

    size_t count = 0;
    auto basePtr = (uint8_t *) (m_file->getMemory()) + Fixed32Size;
#ifndef KFKV_DISABLE_CRYPT
    if (m_crypter) {
        for (auto itr = m_dicCrypt->begin(); itr != m_dicCrypt->end(); NOOP) {
            auto &kvHolder = itr->second;
            assert(kvHolder.realValueSize() >= Fixed32Size);
            if (kvHolder.realValueSize() < Fixed32Size) {
#ifdef KFKV_APPLE
                KFKVWarning("key [%@] has invalid value size %u", itr->first, kvHolder.realValueSize());
#else
                KFKVWarning("key [%s] has invalid value size %u", itr->first.c_str(), kvHolder.realValueSize());
#endif
                itr++;
                continue;
            }
            auto buffer = kvHolder.toKFKVBuffer(basePtr, m_crypter);
            auto ptr = (uint8_t *) buffer.getPtr();
            ptr += buffer.length() - Fixed32Size;
            auto time = *(const uint32_t *) ptr;
            if (time != ExpireNever && time <= now) {
                auto oldKey = itr->first;
                itr = m_dicCrypt->erase(itr);
#    ifdef KFKV_APPLE
                KFKVInfo("deleting expired key [%@], due date %u", oldKey, time);
                
#    else
                KFKVInfo("deleting expired key [%s], due date %u", oldKey.c_str(), time);
#    endif
                count++;
            } else {
                itr++;
            }
        }
    } else
#endif // !KFKV_DISABLE_CRYPT
    {
        for (auto itr = m_dic->begin(); itr != m_dic->end(); NOOP) {
            auto &kvHolder = itr->second;
            assert(kvHolder.valueSize >= Fixed32Size);
            if (kvHolder.valueSize < Fixed32Size) {
#ifdef KFKV_APPLE
                KFKVWarning("key [%@] has invalid value size %u", itr->first, kvHolder.valueSize);
#else
                KFKVWarning("key [%s] has invalid value size %u", itr->first.c_str(), kvHolder.valueSize);
#endif
                itr++;
                continue;
            }
            auto ptr = basePtr + kvHolder.offset + kvHolder.computedKVSize;
            ptr += kvHolder.valueSize - Fixed32Size;
            auto time = *(const uint32_t *) ptr;
            if (time != ExpireNever && time <= now) {
                auto oldKey = itr->first;
                itr = m_dic->erase(itr);
#ifdef KFKV_APPLE
                KFKVInfo("deleting expired key [%@], due date %u", oldKey, time);
                
#else
                KFKVInfo("deleting expired key [%s], due date %u", oldKey.c_str(), time);
#endif
                count++;
            } else {
                itr++;
            }
        }
    }
    if (count != 0) {
        KFKVInfo("deleted %zu expired keys inside [%s]", count, m_mmapID.c_str());
    }
    return count;
}

bool KFKV::enableCompareBeforeSet() {
    KFKVInfo("enableCompareBeforeSet for [%s]", m_mmapID.c_str());
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_exclusiveProcessLock);

    assert(!m_enableKeyExpire && "enableCompareBeforeSet is invalid when Expiration is on");
    assert(!m_crypter && "enableCompareBeforeSet is invalid when key encryption is on");
    if (m_enableKeyExpire || m_crypter) {
        return false;
    }

    m_enableCompareBeforeSet = true;
    return true;
}

bool KFKV::disableCompareBeforeSet() {
    KFKVInfo("disableCompareBeforeSet for [%s]", m_mmapID.c_str());
    SCOPED_LOCK(m_lock);
    SCOPED_LOCK(m_exclusiveProcessLock);

    assert(!m_enableKeyExpire && "disableCompareBeforeSet is invalid when Expiration is on");
    assert(!m_crypter && "disableCompareBeforeSet is invalid when key encryption is on");
    if (m_enableKeyExpire || m_crypter) {
        return false;
    }

    m_enableCompareBeforeSet = false;
    return true;
}

KFKV_NAMESPACE_END
