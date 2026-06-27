
#ifndef KFKVCoreHandler_h
#define KFKVCoreHandler_h

#include "KFKVPredef.h"

#ifdef __cplusplus

namespace kfkv {

// unified callback handler for KFKV
class KFKVHandler {
public:
    virtual ~KFKVHandler() = default;
    
    // by default KFKV will print log using system log
    // implement this method to redirect KFKV's log
    virtual void kfkvLog(KFKVLogLevel level, const char *file, int line, const char *function, KFKVLog_t message) {}
    
    // by default KFKV will discard all data on crc32-check failure
    // return `OnErrorRecover` to recover any data on the file
    virtual KFKVRecoverStrategic onKFKVCRCCheckFail(const std::string &mmapID) { return OnErrorDiscard; }
    
    // by default KFKV will discard all data on file length mismatch
    // return `OnErrorRecover` to recover any data on the file
    virtual KFKVRecoverStrategic onKFKVFileLengthError(const std::string &mmapID) { return OnErrorDiscard; }
    
    // called when content is changed by other process
    // doesn't guarantee real-time notification
    virtual void onContentChangedByOuterProcess(const std::string &mmapID) {}
    
    // called when an KFKV file is loaded successfully
    virtual void onKFKVContentLoadSuccessfully(const std::string &mmapID) {}
};

} // namespace kfkv

#endif

#endif /* KFKVHandler_h */
