
#ifndef KFKVHandler_h
#define KFKVHandler_h
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, KFKVRecoverStrategic) {
    KFKVOnErrorDiscard = 0,
    KFKVOnErrorRecover,
    KFKVOnErrorNotSet,
};

typedef NS_ENUM(NSUInteger, KFKVLogLevel) {
    KFKVLogDebug = 0, // not available for release/product build
    KFKVLogInfo = 1,  // default level
    KFKVLogWarning,
    KFKVLogError,
    KFKVLogNone, // special level used to disable all log messages
};

// callback is called on the operating thread of the KFKV instance
@protocol KFKVHandler <NSObject>
@optional

// by default KFKV will discard all datas on crc32-check failure
// return `KFKVOnErrorRecover` to recover any data on the file
- (KFKVRecoverStrategic)onKFKVCRCCheckFail:(NSString *)mmapID;

// by default KFKV will discard all datas on file length mismatch
// return `KFKVOnErrorRecover` to recover any data on the file
- (KFKVRecoverStrategic)onKFKVFileLengthError:(NSString *)mmapID;

// by default KFKV will print log using NSLog
// implement this method to redirect KFKV's log
- (void)kfkvLogWithLevel:(KFKVLogLevel)level file:(const char *)file line:(int)line func:(const char *)funcname message:(NSString *)message;

// called when content is changed by other process
// doesn't guarantee real-time notification
- (void)onKFKVContentChange:(NSString *)mmapID;

// called when an KFKV file is loaded successfully.
// This is triggered only when KFKV actually opens and maps the file.
- (void)onKFKVContentLoadSuccessfully:(NSString *)mmapID;

@end

#endif /* KFKVHandler_h */
