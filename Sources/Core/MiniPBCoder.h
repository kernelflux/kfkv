
#ifndef KFKV_MINIPBCODER_H
#define KFKV_MINIPBCODER_H
#ifdef __cplusplus

#include "KFKVPredef.h"

#include "KFKVBuffer.h"
#include <cstdint>
#ifdef KFKV_HAS_CPP20
#  include <span>
#  define KFKV_STRING_CONTAINER std::span<const std::string>
#else
#  define KFKV_STRING_CONTAINER std::vector<std::string>
#endif


namespace kfkv {

class CodedInputData;
class CodedOutputData;
class AESCrypt;
class CodedInputDataCrypt;
struct PBEncodeItem;

class KFKV_EXPORT MiniPBCoder {
    const KFKVBuffer *m_inputBuffer = nullptr;
    CodedInputData *m_inputData = nullptr;
    CodedInputDataCrypt *m_inputDataDecrpt = nullptr;

    KFKVBuffer *m_outputBuffer = nullptr;
    CodedOutputData *m_outputData = nullptr;
    std::vector<PBEncodeItem> *m_encodeItems = nullptr;

    MiniPBCoder();
    explicit MiniPBCoder(const KFKVBuffer *inputBuffer, AESCrypt *crypter = nullptr);
    ~MiniPBCoder();

    void writeRootObject();

    size_t prepareObjectForEncode(const KFKVVector &vec);
    size_t prepareObjectForEncode(const KFKVBuffer &buffer);

    template <typename T>
    KFKVBuffer getEncodeData(const T &obj) {
        size_t index = prepareObjectForEncode(obj);
        return writePreparedItems(index);
    }

    KFKVBuffer writePreparedItems(size_t index);

    void decodeOneMap(KFKVMap &dic, size_t position, bool greedy);
#ifndef KFKV_DISABLE_CRYPT
    void decodeOneMap(KFKVMapCrypt &dic, size_t position, bool greedy);
#endif

    size_t prepareObjectForEncode(const std::string &str);
    size_t prepareObjectForEncode(const KFKV_STRING_CONTAINER &vector);
    std::vector<std::string> decodeOneVector();
#ifdef KFKV_HAS_CPP20
    size_t prepareObjectForEncode(const std::span<const int32_t> &vec);
    size_t prepareObjectForEncode(const std::span<const uint32_t> &vec);
    size_t prepareObjectForEncode(const std::span<const int64_t> &vec);
    size_t prepareObjectForEncode(const std::span<const uint64_t> &vec);

    bool decodeOneVector(std::vector<bool> &result);
    bool decodeOneVector(std::vector<int32_t> &result);
    bool decodeOneVector(std::vector<uint32_t> &result);
    bool decodeOneVector(std::vector<int64_t> &result);
    bool decodeOneVector(std::vector<uint64_t> &result);
    bool decodeOneVector(std::vector<float> &result);
    bool decodeOneVector(std::vector<double> &result);

    // special case for fixed size types
    KFKVBuffer getEncodeData(const std::vector<bool> &obj);
    KFKVBuffer getEncodeData(const std::span<const float> &obj);
    KFKVBuffer getEncodeData(const std::span<const double> &obj);
#endif // KFKV_HAS_CPP20

#if defined(KFKV_APPLE) && defined(__OBJC__)
    // NSString, NSData, NSDate
    size_t prepareObjectForEncode(__unsafe_unretained NSObject *obj);
#endif

public:
    template <typename T>
    static KFKVBuffer encodeDataWithObject(const T &obj) {
        MiniPBCoder pbCoder;
        return pbCoder.getEncodeData(obj);
    }

    // opt encoding a single KFKVBuffer
    static KFKVBuffer encodeDataWithObject(const KFKVBuffer &obj);

    // return empty result if there's any error
    static void decodeMap(KFKVMap &dic, const KFKVBuffer &oData, size_t position = 0);

    // decode as much data as possible before any error happens
    static void greedyDecodeMap(KFKVMap &dic, const KFKVBuffer &oData, size_t position = 0);

#ifndef KFKV_DISABLE_CRYPT
    // return empty result if there's any error
    static void decodeMap(KFKVMapCrypt &dic, const KFKVBuffer &oData, AESCrypt *crypter, size_t position = 0);

    // decode as much data as possible before any error happens
    static void greedyDecodeMap(KFKVMapCrypt &dic, const KFKVBuffer &oData, AESCrypt *crypter, size_t position = 0);
#endif // KFKV_DISABLE_CRYPT

    static std::vector<std::string> decodeVector(const KFKVBuffer &oData);

    template <typename T>
    static bool decodeVector(const KFKVBuffer &oData, std::vector<T> &result) {
        MiniPBCoder oCoder(&oData);
        return oCoder.decodeOneVector(result);
    }
#if defined(KFKV_APPLE) && defined(__OBJC__)
    // NSString, NSData, NSDate
    static NSObject *decodeObject(const KFKVBuffer &oData, Class cls);

    static bool isCompatibleClass(Class cls);
#endif

    // just forbid it for possibly misuse
    explicit MiniPBCoder(const MiniPBCoder &other) = delete;
    MiniPBCoder &operator=(const MiniPBCoder &other) = delete;
};

} // namespace kfkv

#endif
#endif //KFKV_MINIPBCODER_H
