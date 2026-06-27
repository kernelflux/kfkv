
#include "MiniPBCoder.h"
#include "KFKVLog.h"

#ifdef KFKV_APPLE

#    include "CodedInputData.h"
#    include "CodedInputDataCrypt.h"
#    include "CodedOutputData.h"
#    include "KFKVBuffer.h"
#    include "PBEncodeItem.hpp"
#    include "PBUtility.h"
#    include <string>
#    include <vector>


using namespace std;

namespace kfkv {

size_t MiniPBCoder::prepareObjectForEncode(__unsafe_unretained NSObject *obj) {
    if (!obj) {
        return m_encodeItems->size();
    }
    m_encodeItems->push_back(PBEncodeItem());
    PBEncodeItem *encodeItem = &(m_encodeItems->back());
    size_t index = m_encodeItems->size() - 1;

    if ([obj isKindOfClass:[NSString class]]) {
        NSString *str = (NSString *) obj;
        encodeItem->type = PBEncodeItemType_NSString;
        NSData *buffer = [str dataUsingEncoding:NSUTF8StringEncoding];
        encodeItem->value.tmpObjectValue = (__bridge_retained void *) buffer;
        encodeItem->valueSize = static_cast<uint32_t>(buffer.length);
    } else if ([obj isKindOfClass:[NSDate class]]) {
        NSDate *oDate = (NSDate *) obj;
        encodeItem->type = PBEncodeItemType_NSDate;
        encodeItem->value.objectValue = (__bridge_retained void *) oDate;
        encodeItem->valueSize = pbDoubleSize();
        encodeItem->compiledSize = encodeItem->valueSize;
        return index; // double has fixed compilesize
    } else if ([obj isKindOfClass:[NSData class]]) {
        NSData *oData = (NSData *) obj;
        encodeItem->type = PBEncodeItemType_NSData;
        encodeItem->value.objectValue = (__bridge_retained void *) oData;
        encodeItem->valueSize = static_cast<uint32_t>(oData.length);
    } else {
        m_encodeItems->pop_back();
        KFKVError("%@ not recognized", NSStringFromClass(obj.class));
        return m_encodeItems->size();
    }
    encodeItem->compiledSize = pbRawVarint32Size(encodeItem->valueSize) + encodeItem->valueSize;

    return index;
}

void MiniPBCoder::decodeOneMap(KFKVMap &dic, size_t position, bool greedy) {
    auto block = [position, this](KFKVMap &dictionary) {
        if (position) {
            m_inputData->seek(position);
        } else {
            m_inputData->readInt32();
        }
        while (!m_inputData->isAtEnd()) {
            KeyValueHolder kvHolder;
            const auto &key = m_inputData->readNSString(kvHolder);
            if (key.length > 0) {
                m_inputData->readData(kvHolder);
                auto itr = dictionary.find(key);
                if (itr != dictionary.end()) {
                    if (kvHolder.valueSize > 0) {
                        itr->second = std::move(kvHolder);
                    } else {
                        auto oldKey = itr->first;
                        dictionary.erase(itr);
                        
                    }
                } else {
                    if (kvHolder.valueSize > 0) {
                        dictionary.emplace(key, std::move(kvHolder));
                        key;
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
            KFKVError("decode fail");
        }
    } else {
        try {
            KFKVMap tmpDic;
            block(tmpDic);
            dic.swap(tmpDic);
            for (auto &pair : tmpDic) {
                
            }
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("decode fail");
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
            const auto &key = m_inputDataDecrpt->readNSString(kvHolder);
            if (key.length > 0) {
                m_inputDataDecrpt->readData(kvHolder);
                auto itr = dictionary.find(key);
                if (itr != dictionary.end()) {
                    if (kvHolder.realValueSize() > 0) {
                        itr->second = std::move(kvHolder);
                    } else {
                        auto oldKey = itr->first;
                        dictionary.erase(itr);
                        
                    }
                } else {
                    if (kvHolder.realValueSize() > 0) {
                        dictionary.emplace(key, std::move(kvHolder));
                        key;
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
            KFKVError("decode fail");
        }
    } else {
        try {
            KFKVMapCrypt tmpDic;
            block(tmpDic);
            dic.swap(tmpDic);
            for (auto &pair : tmpDic) {
                
            }
        } catch (std::exception &exception) {
            KFKVError("%s", exception.what());
        } catch (...) {
            KFKVError("decode fail");
        }
    }
}

#    endif // KFKV_DISABLE_CRYPT

NSObject *MiniPBCoder::decodeObject(const KFKVBuffer &oData, Class cls) {
    if (!cls || oData.length() == 0) {
        return nil;
    }
    CodedInputData input(oData.getPtr(), oData.length());
    if (cls == [NSString class]) {
        return input.readNSString();
    } else if (cls == [NSMutableString class]) {
        return [NSMutableString stringWithString:input.readNSString()];
    } else if (cls == [NSData class]) {
        return input.readNSData();
    } else if (cls == [NSMutableData class]) {
        return [NSMutableData dataWithData:input.readNSData()];
    } else if (cls == [NSDate class]) {
        return [NSDate dateWithTimeIntervalSince1970:input.readDouble()];
    } else {
        KFKVError("%@ not recognized", NSStringFromClass(cls));
    }

    return nil;
}

bool MiniPBCoder::isCompatibleClass(Class cls) {
    if (cls == [NSString class]) {
        return true;
    }
    if (cls == [NSMutableString class]) {
        return true;
    }
    if (cls == [NSData class]) {
        return true;
    }
    if (cls == [NSMutableData class]) {
        return true;
    }
    if (cls == [NSDate class]) {
        return true;
    }

    return false;
}

} // namespace kfkv

#endif // KFKV_APPLE
