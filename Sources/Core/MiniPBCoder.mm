
#include "MiniPBCoder.h"
#include "CodedInputData.h"
#include "CodedInputDataCrypt.h"
#include "CodedOutputData.h"
#include "PBEncodeItem.hpp"
#include "PBUtility.h"
#include "KFKVLog.h"

#ifdef KFKV_APPLE
#endif // KFKV_APPLE

using namespace std;

namespace kfkv {

MiniPBCoder::MiniPBCoder() : m_encodeItems(new std::vector<PBEncodeItem>()) {
}

MiniPBCoder::MiniPBCoder(const KFKVBuffer *inputBuffer, AESCrypt *crypter) : MiniPBCoder() {
    m_inputBuffer = inputBuffer;
#ifndef KFKV_DISABLE_CRYPT
    if (crypter) {
        m_inputDataDecrpt = new CodedInputDataCrypt(m_inputBuffer->getPtr(), m_inputBuffer->length(), *crypter);
    } else {
        m_inputData = new CodedInputData(m_inputBuffer->getPtr(), m_inputBuffer->length());
    }
#else
    m_inputData = new CodedInputData(m_inputBuffer->getPtr(), m_inputBuffer->length());
#endif // KFKV_DISABLE_CRYPT
}

MiniPBCoder::~MiniPBCoder() {
    delete m_inputData;
#ifndef KFKV_DISABLE_CRYPT
    delete m_inputDataDecrpt;
#endif
    delete m_outputBuffer;
    delete m_outputData;
    delete m_encodeItems;
}

// encode

// write object using prepared m_encodeItems[]
void MiniPBCoder::writeRootObject() {
    for (size_t index = 0, total = m_encodeItems->size(); index < total; index++) {
        PBEncodeItem *encodeItem = &(*m_encodeItems)[index];
        switch (encodeItem->type) {
            case PBEncodeItemType_Data: {
                m_outputData->writeData(*(encodeItem->value.bufferValue));
                break;
            }
            case PBEncodeItemType_Container: {
                m_outputData->writeUInt32(encodeItem->valueSize);
                break;
            }
#ifdef KFKV_HAS_CPP20
            case PBEncodeItemType_Int32: {
                m_outputData->writeInt32(encodeItem->value.int32Value);
                break;
            }
            case PBEncodeItemType_UInt32: {
                m_outputData->writeUInt32(encodeItem->value.uint32Value);
                break;
            }
            case PBEncodeItemType_Int64: {
                m_outputData->writeInt64(encodeItem->value.int64Value);
                break;
            }
            case PBEncodeItemType_UInt64: {
                m_outputData->writeUInt64(encodeItem->value.uint64Value);
                break;
            }
#endif // KFKV_HAS_CPP20
            case PBEncodeItemType_String: {
                m_outputData->writeString(*(encodeItem->value.strValue));
                break;
            }
#ifdef KFKV_APPLE
            case PBEncodeItemType_NSString: {
                m_outputData->writeUInt32(encodeItem->valueSize);
                if (encodeItem->valueSize > 0 && encodeItem->value.tmpObjectValue != nullptr) {
                    auto obj = (__bridge_transfer NSData *) encodeItem->value.tmpObjectValue;
                    KFKVBuffer buffer(obj, KFKVBufferNoCopy);
                    m_outputData->writeRawData(buffer);
                }
                break;
            }
            case PBEncodeItemType_NSData: {
                m_outputData->writeUInt32(encodeItem->valueSize);
                if (encodeItem->valueSize > 0 && encodeItem->value.objectValue != nullptr) {
                    auto obj = (__bridge_transfer NSData *) encodeItem->value.objectValue;
                    KFKVBuffer buffer(obj, KFKVBufferNoCopy);
                    m_outputData->writeRawData(buffer);
                }
                break;
            }
            case PBEncodeItemType_NSDate: {
                NSDate *oDate = (__bridge_transfer NSDate *) encodeItem->value.objectValue;
                m_outputData->writeDouble(oDate.timeIntervalSince1970);
                break;
            }
#endif // KFKV_APPLE
            case PBEncodeItemType_None: {
                KFKVError("%d", encodeItem->type);
                break;
            }
        }
    }
}

size_t MiniPBCoder::prepareObjectForEncode(const KFKVBuffer &buffer) {
    m_encodeItems->push_back(PBEncodeItem());
    PBEncodeItem *encodeItem = &(m_encodeItems->back());
    size_t index = m_encodeItems->size() - 1;
    {
        encodeItem->type = PBEncodeItemType_Data;
        encodeItem->value.bufferValue = &buffer;
        encodeItem->valueSize = static_cast<uint32_t>(buffer.length());
    }
    encodeItem->compiledSize = pbRawVarint32Size(encodeItem->valueSize) + encodeItem->valueSize;

    return index;
}

size_t MiniPBCoder::prepareObjectForEncode(const KFKVVector &vec) {
    m_encodeItems->push_back(PBEncodeItem());
    PBEncodeItem *encodeItem = &(m_encodeItems->back());
    size_t index = m_encodeItems->size() - 1;
    {
        encodeItem->type = PBEncodeItemType_Container;
        encodeItem->value.bufferValue = nullptr;

        for (const auto &itr : vec) {
            const auto &key = itr.first;
            const auto &value = itr.second;
#    ifdef KFKV_APPLE
            if (key.length <= 0) {
#    else
            if (key.length() <= 0) {
#    endif
                continue;
            }

            size_t keyIndex = prepareObjectForEncode(key);
            if (keyIndex < m_encodeItems->size()) {
                size_t valueIndex = prepareObjectForEncode(value);
                if (valueIndex < m_encodeItems->size()) {
                    (*m_encodeItems)[index].valueSize += (*m_encodeItems)[keyIndex].compiledSize;
                    (*m_encodeItems)[index].valueSize += (*m_encodeItems)[valueIndex].compiledSize;
                } else {
                    m_encodeItems->pop_back(); // pop key
                }
            }
        }

        encodeItem = &(*m_encodeItems)[index];
    }
    encodeItem->compiledSize = pbRawVarint32Size(encodeItem->valueSize) + encodeItem->valueSize;

    return index;
}

KFKVBuffer MiniPBCoder::writePreparedItems(size_t index) {
    try {
        PBEncodeItem *oItem = (index < m_encodeItems->size()) ? &(*m_encodeItems)[index] : nullptr;
        if (oItem && oItem->compiledSize > 0) {
            m_outputBuffer = new KFKVBuffer(oItem->compiledSize);
            m_outputData = new CodedOutputData(m_outputBuffer->getPtr(), m_outputBuffer->length());

            writeRootObject();
        }

        return std::move(*m_outputBuffer);
    } catch (const std::exception &exception) {
        KFKVError("%s", exception.what());
        return KFKVBuffer();
    } catch (...) {
        KFKVError("encode fail");
        return KFKVBuffer();
    }
}

KFKVBuffer MiniPBCoder::encodeDataWithObject(const KFKVBuffer &obj) {
    try {
        auto valueSize = static_cast<uint32_t>(obj.length());
        auto compiledSize = pbRawVarint32Size(valueSize) + valueSize;
        KFKVBuffer result(compiledSize);
        CodedOutputData output(result.getPtr(), result.length());
        output.writeData(obj);
        return result;
    } catch (const std::exception &exception) {
        KFKVError("%s", exception.what());
        return KFKVBuffer();
    } catch (...) {
        KFKVError("prepare encode fail");
        return KFKVBuffer();
    }
}

size_t MiniPBCoder::prepareObjectForEncode(const string &str) {
    m_encodeItems->push_back(PBEncodeItem());
    PBEncodeItem *encodeItem = &(m_encodeItems->back());
    size_t index = m_encodeItems->size() - 1;
    {
        encodeItem->type = PBEncodeItemType_String;
        encodeItem->value.strValue = &str;
        encodeItem->valueSize = static_cast<uint32_t>(str.size());
    }
    encodeItem->compiledSize = pbRawVarint32Size(encodeItem->valueSize) + encodeItem->valueSize;

    return index;
}

size_t MiniPBCoder::prepareObjectForEncode(const KFKV_STRING_CONTAINER &v) {
    m_encodeItems->push_back(PBEncodeItem());
    PBEncodeItem *encodeItem = &(m_encodeItems->back());
    size_t index = m_encodeItems->size() - 1;
    {
        encodeItem->type = PBEncodeItemType_Container;
        encodeItem->value.bufferValue = nullptr;

        for (const auto &str : v) {
            size_t itemIndex = prepareObjectForEncode(str);
            if (itemIndex < m_encodeItems->size()) {
                (*m_encodeItems)[index].valueSize += (*m_encodeItems)[itemIndex].compiledSize;
            }
        }

        encodeItem = &(*m_encodeItems)[index];
    }
    encodeItem->compiledSize = pbRawVarint32Size(encodeItem->valueSize) + encodeItem->valueSize;

    return index;
}

#ifdef KFKV_HAS_CPP20

size_t MiniPBCoder::prepareObjectForEncode(const std::span<const int32_t> &vec) {
    m_encodeItems->push_back(PBEncodeItem());
    PBEncodeItem *encodeItem = &(m_encodeItems->back());
    size_t index = m_encodeItems->size() - 1;
    {
        encodeItem->type = PBEncodeItemType_Container;
        encodeItem->value.bufferValue = nullptr;

        for (const auto value : vec) {
            PBEncodeItem item;
            item.type = PBEncodeItemType_Int32;
            item.value.int32Value = value;
            item.compiledSize = pbInt32Size(value);

            (*m_encodeItems)[index].valueSize += item.compiledSize;
            m_encodeItems->push_back(std::move(item));
        }

        encodeItem = &(*m_encodeItems)[index];
    }
    encodeItem->compiledSize = pbRawVarint32Size(encodeItem->valueSize) + encodeItem->valueSize;

    return index;
}

size_t MiniPBCoder::prepareObjectForEncode(const std::span<const uint32_t> &vec) {
    m_encodeItems->push_back(PBEncodeItem());
    PBEncodeItem *encodeItem = &(m_encodeItems->back());
    size_t index = m_encodeItems->size() - 1;
    {
        encodeItem->type = PBEncodeItemType_Container;
        encodeItem->value.bufferValue = nullptr;

        for (const auto value : vec) {
            PBEncodeItem item;
            item.type = PBEncodeItemType_UInt32;
            item.value.uint32Value = value;
            item.compiledSize = pbUInt32Size(value);

            (*m_encodeItems)[index].valueSize += item.compiledSize;
            m_encodeItems->push_back(std::move(item));
        }

        encodeItem = &(*m_encodeItems)[index];
    }
    encodeItem->compiledSize = pbRawVarint32Size(encodeItem->valueSize) + encodeItem->valueSize;

    return index;
}

size_t MiniPBCoder::prepareObjectForEncode(const std::span<const int64_t> &vec) {
    m_encodeItems->push_back(PBEncodeItem());
    PBEncodeItem *encodeItem = &(m_encodeItems->back());
    size_t index = m_encodeItems->size() - 1;
    {
        encodeItem->type = PBEncodeItemType_Container;
        encodeItem->value.bufferValue = nullptr;

        for (const auto value : vec) {
            PBEncodeItem item;
            item.type = PBEncodeItemType_Int64;
            item.value.int64Value = value;
            item.compiledSize = pbInt64Size(value);

            (*m_encodeItems)[index].valueSize += item.compiledSize;
            m_encodeItems->push_back(std::move(item));
        }

        encodeItem = &(*m_encodeItems)[index];
    }
    encodeItem->compiledSize = pbRawVarint32Size(encodeItem->valueSize) + encodeItem->valueSize;

    return index;
}

size_t MiniPBCoder::prepareObjectForEncode(const std::span<const uint64_t> &vec) {
    m_encodeItems->push_back(PBEncodeItem());
    PBEncodeItem *encodeItem = &(m_encodeItems->back());
    size_t index = m_encodeItems->size() - 1;
    {
        encodeItem->type = PBEncodeItemType_Container;
        encodeItem->value.bufferValue = nullptr;

        for (const auto value : vec) {
            PBEncodeItem item;
            item.type = PBEncodeItemType_UInt64;
            item.value.uint64Value = value;
            item.compiledSize = pbUInt64Size(value);

            (*m_encodeItems)[index].valueSize += item.compiledSize;
            m_encodeItems->push_back(std::move(item));
        }

        encodeItem = &(*m_encodeItems)[index];
    }
    encodeItem->compiledSize = pbRawVarint32Size(encodeItem->valueSize) + encodeItem->valueSize;

    return index;
}

#endif // KFKV_HAS_CPP20

vector<string> MiniPBCoder::decodeOneVector() {
    vector<string> v;

    m_inputData->readInt32();

    while (!m_inputData->isAtEnd()) {
        auto value = m_inputData->readString();
        v.push_back(std::move(value));
    }

    return v;
}

#ifdef KFKV_HAS_CPP20

bool MiniPBCoder::decodeOneVector(std::vector<bool> &result) {
    try {
        auto size = m_inputData->readUInt32();
        result.reserve(size / pbBoolSize());

        while (!m_inputData->isAtEnd()) {
            auto value = m_inputData->readBool();
            result.push_back(value);
        }
        return true;
    } catch (std::exception &exception) {
        KFKVError("%s", exception.what());
    } catch (...) {
        KFKVError("decode fail");
    }
    return false;
}

bool MiniPBCoder::decodeOneVector(std::vector<int32_t> &result) {
    try {
        m_inputData->readInt32();

        while (!m_inputData->isAtEnd()) {
            auto value = m_inputData->readInt32();
            result.push_back(value);
        }
        return true;
    } catch (std::exception &exception) {
        KFKVError("%s", exception.what());
    } catch (...) {
        KFKVError("decode fail");
    }
    return false;
}

bool MiniPBCoder::decodeOneVector(std::vector<uint32_t> &result) {
    try {
        m_inputData->readInt32();

        while (!m_inputData->isAtEnd()) {
            auto value = m_inputData->readUInt32();
            result.push_back(value);
        }
        return true;
    } catch (std::exception &exception) {
        KFKVError("%s", exception.what());
    } catch (...) {
        KFKVError("decode fail");
    }
    return false;
}

bool MiniPBCoder::decodeOneVector(std::vector<int64_t> &result) {
    try {
        m_inputData->readInt32();

        while (!m_inputData->isAtEnd()) {
            auto value = m_inputData->readInt64();
            result.push_back(value);
        }
        return true;
    } catch (std::exception &exception) {
        KFKVError("%s", exception.what());
    } catch (...) {
        KFKVError("decode fail");
    }
    return false;
}

bool MiniPBCoder::decodeOneVector(std::vector<uint64_t> &result) {
    try {
        m_inputData->readInt32();

        while (!m_inputData->isAtEnd()) {
            auto value = m_inputData->readUInt64();
            result.push_back(value);
        }
        return true;
    } catch (std::exception &exception) {
        KFKVError("%s", exception.what());
    } catch (...) {
        KFKVError("decode fail");
    }
    return false;
}

bool MiniPBCoder::decodeOneVector(std::vector<float> &result) {
    try {
        auto size = m_inputData->readUInt32();
        result.reserve(size / pbFloatSize());

        while (!m_inputData->isAtEnd()) {
            auto value = m_inputData->readFloat();
            result.push_back(value);
        }
        return true;
    } catch (std::exception &exception) {
        KFKVError("%s", exception.what());
    } catch (...) {
        KFKVError("decode fail");
    }
    return false;
}

bool MiniPBCoder::decodeOneVector(std::vector<double> &result) {
    try {
        auto size = m_inputData->readUInt32();
        result.reserve(size / pbDoubleSize());

        while (!m_inputData->isAtEnd()) {
            auto value = m_inputData->readDouble();
            result.push_back(value);
        }
        return true;
    } catch (std::exception &exception) {
        KFKVError("%s", exception.what());
    } catch (...) {
        KFKVError("decode fail");
    }
    return false;
}

#endif // KFKV_HAS_CPP20

#ifndef KFKV_APPLE
void MiniPBCoder::decodeOneMap(KFKVMap &dic, size_t position, bool greedy) {
    auto block = [position, this](KFKVMap &dictionary) {
        if (position) {
            m_inputData->seek(position);
        } else {
            m_inputData->readInt32();
        }
        while (!m_inputData->isAtEnd()) {
            KeyValueHolder kvHolder;
            const auto &key = m_inputData->readString(kvHolder);
            if (key.length() > 0) {
                m_inputData->readData(kvHolder);
                if (kvHolder.valueSize > 0) {
                    dictionary[key] = std::move(kvHolder);
                } else {
                    auto itr = dictionary.find(key);
                    if (itr != dictionary.end()) {
                        dictionary.erase(itr);
                    }
                }
            }
        }
    };

    if (greedy) {
        try {
            block(dic);
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("prepare encode fail");
        }
    } else {
        try {
            KFKVMap tmpDic;
            block(tmpDic);
            dic.swap(tmpDic);
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("prepare encode fail");
        }
    }
}

#    ifndef KFKV_DISABLE_CRYPT

void MiniPBCoder::decodeOneMap(KFKVMapCrypt &dic, size_t position, bool greedy) {
    auto block = [position, this](KFKVMapCrypt &dictionary) {
        if (position) {
            m_inputDataDecrpt->seek(position);
        } else {
            m_inputDataDecrpt->readInt32();
        }
        while (!m_inputDataDecrpt->isAtEnd()) {
            KeyValueHolderCrypt kvHolder;
            const auto &key = m_inputDataDecrpt->readString(kvHolder);
            if (key.length() > 0) {
                m_inputDataDecrpt->readData(kvHolder);
                if (kvHolder.realValueSize() > 0) {
                    dictionary[key] = std::move(kvHolder);
                } else {
                    auto itr = dictionary.find(key);
                    if (itr != dictionary.end()) {
                        dictionary.erase(itr);
                    }
                }
            }
        }
    };

    if (greedy) {
        try {
            block(dic);
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("prepare encode fail");
        }
    } else {
        try {
            KFKVMapCrypt tmpDic;
            block(tmpDic);
            dic.swap(tmpDic);
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("prepare encode fail");
        }
    }
}
#endif // !KFKV_APPLE
#    endif // KFKV_DISABLE_CRYPT

vector<string> MiniPBCoder::decodeVector(const KFKVBuffer &oData) {
    MiniPBCoder oCoder(&oData);
    return oCoder.decodeOneVector();
}

#ifdef KFKV_HAS_CPP20
KFKVBuffer MiniPBCoder::getEncodeData(const std::vector<bool> &value) {
    auto valueLength = static_cast<uint32_t>(value.size() * pbBoolSize());
    auto size = pbRawVarint32Size(valueLength) + valueLength;
    auto buffer = KFKVBuffer(size);
    CodedOutputData output(buffer.getPtr(), size);
    output.writeUInt32(valueLength);

    for (auto single : value) {
        output.writeBool(single);
    }
    return buffer;
}

KFKVBuffer MiniPBCoder::getEncodeData(const std::span<const float> &value) {
    auto valueLength = static_cast<uint32_t>(value.size() * pbFloatSize());
    auto size = pbRawVarint32Size(valueLength) + valueLength;
    auto buffer = KFKVBuffer(size);
    CodedOutputData output(buffer.getPtr(), size);
    output.writeUInt32(valueLength);

    for (auto single : value) {
        output.writeFloat(single);
    }
    return buffer;
}

KFKVBuffer MiniPBCoder::getEncodeData(const std::span<const double> &value) {
    auto valueLength = static_cast<uint32_t>(value.size() * pbDoubleSize());
    auto size = pbRawVarint32Size(valueLength) + valueLength;
    auto buffer = KFKVBuffer(size);
    CodedOutputData output(buffer.getPtr(), size);
    output.writeUInt32(valueLength);

    for (auto single : value) {
        output.writeDouble(single);
    }
    return buffer;
}
#endif // KFKV_HAS_CPP20

void MiniPBCoder::decodeMap(KFKVMap &dic, const KFKVBuffer &oData, size_t position) {
    MiniPBCoder oCoder(&oData);
    oCoder.decodeOneMap(dic, position, false);
}

void MiniPBCoder::greedyDecodeMap(KFKVMap &dic, const KFKVBuffer &oData, size_t position) {
    MiniPBCoder oCoder(&oData);
    oCoder.decodeOneMap(dic, position, true);
}

#ifndef KFKV_DISABLE_CRYPT

void MiniPBCoder::decodeMap(KFKVMapCrypt &dic, const KFKVBuffer &oData, AESCrypt *crypter, size_t position) {
    MiniPBCoder oCoder(&oData, crypter);
    oCoder.decodeOneMap(dic, position, false);
}

void MiniPBCoder::greedyDecodeMap(KFKVMapCrypt &dic, const KFKVBuffer &oData, AESCrypt *crypter, size_t position) {
    MiniPBCoder oCoder(&oData, crypter);
    oCoder.decodeOneMap(dic, position, true);
}

#endif

} // namespace kfkv
