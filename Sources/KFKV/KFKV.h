
#import "KFKVHandler.h"

#ifndef KFKV_OUT
#define KFKV_OUT
#endif

typedef NS_ENUM(NSUInteger, KFKVMode) {
    KFKVSingleProcess = 1 << 0,
    KFKVMultiProcess = 1 << 1,
    // 2~4 are preserved for Android
    KFKVReadOnly = 1 << 5,
};

typedef NS_ENUM(UInt32, KFKVExpireDuration) {
    KFKVExpireNever = 0,
    KFKVExpireInMinute = 60,
    KFKVExpireInHour = 60 * 60,
    KFKVExpireInDay = 24 * 60 * 60,
    KFKVExpireInMonth = 30 * 24 * 60 * 60,
    KFKVExpireInYear = 365 * 30 * 24 * 60 * 60,
};

// all-in-one configuration for creating KFKV instance
typedef struct {
    KFKVMode mode; // = KFKVSingleProcess;

    // using AES-256 key length
    BOOL aes256; // = NO;
    NSData * _Nullable cryptKey; // = nil;

    NSString * _Nullable rootPath; // = nil;

    // the initial file size
    size_t expectedCapacity; // = 0;

    /// @YES / @NO to set this value
    /// if nil, auto expire is off
    NSNumber * _Nullable enableKeyExpire; // = nil;
    uint32_t expiredInSeconds; // = KFKVExpireNever;

    BOOL enableCompareBeforeSet; // = NO;

    // if not set, use the old style callback
    KFKVRecoverStrategic recover; // = KFKVOnErrorNotSet;

    // the size limit of a key-value pair, reject insert if pass limit
    uint32_t itemSizeLimit; // = 0;
} KFKVConfig;

static inline KFKVConfig KFKVConfigDefault(void) {
    KFKVConfig config = {
        .mode = KFKVSingleProcess, .aes256 = NO, .cryptKey = nil, .rootPath = nil,
        .expectedCapacity = 0, .enableKeyExpire = nil, .expiredInSeconds = KFKVExpireNever,
        .enableCompareBeforeSet = NO, .recover = KFKVOnErrorNotSet, .itemSizeLimit = 0,
    };
    return config;
}

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
namespace kfkv {
class KFKV;
}
#endif

@class KFKVNameSpace;

@interface KFKVEngine : NSObject

/// call this in main thread, before calling any other KFKV methods
/// @param rootDir the root dir of KFKV, passing nil defaults to {NSDocumentDirectory}/kfkv
/// @return root dir of KFKV
+ (NSString *)initializeKFKV:(nullable NSString *)rootDir NS_SWIFT_NAME(initialize(rootDir:));

/// call this in main thread, before calling any other KFKV methods
/// @param rootDir the root dir of KFKV, passing nil defaults to {NSDocumentDirectory}/kfkv
/// @param logLevel KFKVLogInfo by default, KFKVLogNone to disable all logging
/// @return root dir of KFKV
+ (NSString *)initializeKFKV:(nullable NSString *)rootDir logLevel:(KFKVLogLevel)logLevel NS_SWIFT_NAME(initialize(rootDir:logLevel:));

/// call this in main thread, before calling any other KFKV methods
/// @param rootDir the root dir of KFKV, passing nil defaults to {NSDocumentDirectory}/kfkv
/// @param logLevel KFKVLogInfo by default, KFKVLogNone to disable all logging
/// @return root dir of KFKV
+ (NSString *)initializeKFKV:(nullable NSString *)rootDir logLevel:(KFKVLogLevel)logLevel handler:(nullable id<KFKVHandler>)handler NS_SWIFT_NAME(initialize(rootDir:logLevel:handler:));

/// call this in main thread, before calling any other KFKV methods
/// @param rootDir the root dir of KFKV, passing nil defaults to {NSDocumentDirectory}/kfkv
/// @param groupDir the root dir of multi-process KFKV, KFKV with KFKVMultiProcess mode will be stored in groupDir/kfkv
/// @param logLevel KFKVLogInfo by default, KFKVLogNone to disable all logging
/// @return root dir of KFKV
+ (NSString *)initializeKFKV:(nullable NSString *)rootDir groupDir:(NSString *)groupDir logLevel:(KFKVLogLevel)logLevel NS_SWIFT_NAME(initialize(rootDir:groupDir:logLevel:));

/// call this in main thread, before calling any other KFKV methods
/// @param rootDir the root dir of KFKV, passing nil defaults to {NSDocumentDirectory}/kfkv
/// @param groupDir the root dir of multi-process KFKV, KFKV with KFKVMultiProcess mode will be stored in groupDir/kfkv
/// @param logLevel KFKVLogInfo by default, KFKVLogNone to disable all logging
/// @return root dir of KFKV
+ (NSString *)initializeKFKV:(nullable NSString *)rootDir groupDir:(NSString *)groupDir logLevel:(KFKVLogLevel)logLevel handler:(nullable id<KFKVHandler>)handler NS_SWIFT_NAME(initialize(rootDir:groupDir:logLevel:handler:));

/// a generic purpose instance (in KFKVSingleProcess mode)
+ (nullable instancetype)defaultKFKV NS_SWIFT_NAME(default());

/// an encrypted generic purpose instance (in KFKVSingleProcess mode)
+ (nullable instancetype)defaultKFKVWithConfig:(KFKVConfig)config NS_SWIFT_NAME(default(config:));

/// an encrypted generic purpose instance (in KFKVSingleProcess mode)
+ (nullable instancetype)defaultKFKVWithCryptKey:(nullable NSData *)cryptKey NS_SWIFT_NAME(default(cryptKey:));

/// an encrypted generic purpose instance (in KFKVSingleProcess mode)
/// @param aes256 use aes 256 key length
+ (nullable instancetype)defaultKFKVWithCryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 NS_SWIFT_NAME(default(cryptKey:aes256:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID NS_SWIFT_NAME(init(mmapID:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID config:(KFKVConfig)config NS_SWIFT_NAME(init(mmapID:config:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param expectedCapacity the file size you expected when opening or creating file
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID expectedCapacity:(size_t)expectedCapacity NS_SWIFT_NAME(init(mmapID:expectedCapacity:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param mode KFKVReadOnly for readonly KFKV, KFKVMultiProcess for multi-process KFKV
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID mode:(KFKVMode)mode NS_SWIFT_NAME(init(mmapID:mode:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 16 bytes at most
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey NS_SWIFT_NAME(init(mmapID:cryptKey:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 32 bytes at most
/// @param aes256 use aes 256 key length
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 NS_SWIFT_NAME(init(mmapID:cryptKey:aes256:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 16 bytes at most
/// @param expectedCapacity the file size you expected when opening or creating file
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey expectedCapacity:(size_t)expectedCapacity NS_SWIFT_NAME(init(mmapID:cryptKey:expectedCapacity:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 32 bytes at most
/// @param aes256 use aes 256 key length
/// @param expectedCapacity the file size you expected when opening or creating file
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 expectedCapacity:(size_t)expectedCapacity NS_SWIFT_NAME(init(mmapID:cryptKey:aes256:expectedCapacity:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 16 bytes at most
/// @param mode KFKVReadOnly for readonly KFKV, KFKVMultiProcess for multi-process KFKV
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey mode:(KFKVMode)mode NS_SWIFT_NAME(init(mmapID:cryptKey:mode:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 32 bytes at most
/// @param aes256 use aes 256 key length
/// @param mode KFKVReadOnly for readonly KFKV, KFKVMultiProcess for multi-process KFKV
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 mode:(KFKVMode)mode NS_SWIFT_NAME(init(mmapID:cryptKey:aes256:mode:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param rootPath custom path of the file, `NSDocumentDirectory/kfkv` by default
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID rootPath:(nullable NSString *)rootPath NS_SWIFT_NAME(init(mmapID:rootPath:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param rootPath custom path of the file, `NSDocumentDirectory/kfkv` by default
/// @param expectedCapacity the file size you expected when opening or creating file
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID rootPath:(nullable NSString *)rootPath expectedCapacity:(size_t)expectedCapacity NS_SWIFT_NAME(init(mmapID:rootPath:expectedCapacity:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 16 bytes at most
/// @param rootPath custom path of the file, `NSDocumentDirectory/kfkv` by default
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey rootPath:(nullable NSString *)rootPath NS_SWIFT_NAME(init(mmapID:cryptKey:rootPath:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 32 bytes at most
/// @param aes256 use aes 256 key length
/// @param rootPath custom path of the file, `NSDocumentDirectory/kfkv` by default
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 rootPath:(nullable NSString *)rootPath NS_SWIFT_NAME(init(mmapID:cryptKey:aes256:rootPath:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 16 bytes at most
/// @param rootPath custom path of the file, `NSDocumentDirectory/kfkv` by default
/// @param expectedCapacity the file size you expected when opening or creating file
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey rootPath:(nullable NSString *)rootPath expectedCapacity:(size_t)expectedCapacity NS_SWIFT_NAME(init(mmapID:cryptKey:rootPath:expectedCapacity:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 16 bytes at most
/// @param rootPath custom path of the file, `NSDocumentDirectory/kfkv` by default
/// @param mode KFKVReadOnly for readonly KFKV, KFKVMultiProcess for multi-process KFKV
/// @param expectedCapacity the file size you expected when opening or creating file
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey rootPath:(nullable NSString *)rootPath mode:(KFKVMode)mode expectedCapacity:(size_t)expectedCapacity NS_SWIFT_NAME(init(mmapID:cryptKey:rootPath:mode:expectedCapacity:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 32 bytes at most
/// @param aes256 use aes 256 key length
/// @param rootPath custom path of the file, `NSDocumentDirectory/kfkv` by default
/// @param mode KFKVReadOnly for readonly KFKV, KFKVMultiProcess for multi-process KFKV
/// @param expectedCapacity the file size you expected when opening or creating file
+ (nullable instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 rootPath:(nullable NSString *)rootPath mode:(KFKVMode)mode expectedCapacity:(size_t)expectedCapacity  NS_SWIFT_NAME(init(mmapID:cryptKey:aes256:rootPath:mode:expectedCapacity:));

/// you can call this on applicationWillTerminate, it's totally fine if you don't call
+ (void)onAppTerminate;

+ (NSString *)kfkvBasePath;
+ (nullable NSString *)kfkvGroupPath;

/// get a namespace with custom root dir
+ (KFKVNameSpace *)nameSpace:(NSString *)rootPath;

/// identical with the original KFKV with the global root dir
+ (nullable KFKVNameSpace *)defaultNameSpace;

/// if you want to change the base path, do it BEFORE getting any KFKV instance
/// otherwise the behavior is undefined
+ (void)setKFKVBasePath:(NSString *)basePath __attribute__((deprecated("use +initializeKFKV: instead", "+initializeKFKV:")));

// protection from possible misuse
- (void)setValue:(nullable id)value forKey:(NSString *)key __attribute__((deprecated("use setObject:forKey: instead")));
- (void)setValue:(nullable id)value forKeyPath:(NSString *)keyPath __attribute__((deprecated("use setObject:forKey: instead")));

- (NSString *)mmapID;

/// transform plain text into encrypted text, or vice versa by passing newKey = nil
/// you can change existing crypt key with different key
/// @param newKey 16 bytes at most
- (BOOL)reKey:(nullable NSData *)newKey NS_SWIFT_NAME(reset(cryptKey:));

/// transform plain text into encrypted text, or vice versa by passing newKey = nil
/// you can change existing crypt key with different key
/// @param newKey 32 bytes at most
/// @param aes256 use aes 256 key length
- (BOOL)reKey:(nullable NSData *)newKey aes256:(BOOL)aes256 NS_SWIFT_NAME(reset(cryptKey:aes256:));

- (nullable NSData *)cryptKey;

/// just reset cryptKey (will not encrypt or decrypt anything)
/// usually you should call this method after other process reKey() the multi-process kfkv
/// @param cryptKey 16 bytes at most
- (void)checkReSetCryptKey:(nullable NSData *)cryptKey NS_SWIFT_NAME(checkReSet(cryptKey:));

/// just reset cryptKey (will not encrypt or decrypt anything)
/// usually you should call this method after other process reKey() the multi-process kfkv
/// @param cryptKey 32 bytes at most
/// @param aes256 use aes 256 key length
- (void)checkReSetCryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 NS_SWIFT_NAME(checkReSet(cryptKey:aes256:));

- (BOOL)setObject:(nullable NSObject<NSCoding> *)object forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));
- (BOOL)setObject:(nullable NSObject<NSCoding> *)object forKey:(NSString *)key expireDuration:(uint32_t)seconds NS_SWIFT_NAME(set(_:forKey:expireDuration:));

- (BOOL)setBool:(BOOL)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));
- (BOOL)setBool:(BOOL)value forKey:(NSString *)key expireDuration:(uint32_t)seconds NS_SWIFT_NAME(set(_:forKey:expireDuration:));

- (BOOL)setInt32:(int32_t)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));
- (BOOL)setInt32:(int32_t)value forKey:(NSString *)key expireDuration:(uint32_t)seconds NS_SWIFT_NAME(set(_:forKey:expireDuration:));

- (BOOL)setUInt32:(uint32_t)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));
- (BOOL)setUInt32:(uint32_t)value forKey:(NSString *)key expireDuration:(uint32_t)seconds NS_SWIFT_NAME(set(_:forKey:expireDuration:));

- (BOOL)setInt64:(int64_t)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));
- (BOOL)setInt64:(int64_t)value forKey:(NSString *)key expireDuration:(uint32_t)seconds NS_SWIFT_NAME(set(_:forKey:expireDuration:));

- (BOOL)setUInt64:(uint64_t)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));
- (BOOL)setUInt64:(uint64_t)value forKey:(NSString *)key expireDuration:(uint32_t)seconds NS_SWIFT_NAME(set(_:forKey:expireDuration:));

- (BOOL)setFloat:(float)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));
- (BOOL)setFloat:(float)value forKey:(NSString *)key expireDuration:(uint32_t)seconds NS_SWIFT_NAME(set(_:forKey:expireDuration:));

- (BOOL)setDouble:(double)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));
- (BOOL)setDouble:(double)value forKey:(NSString *)key expireDuration:(uint32_t)seconds NS_SWIFT_NAME(set(_:forKey:expireDuration:));

- (BOOL)setString:(NSString *)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));
- (BOOL)setString:(NSString *)value forKey:(NSString *)key expireDuration:(uint32_t)seconds NS_SWIFT_NAME(set(_:forKey:expireDuration:));

- (BOOL)setDate:(NSDate *)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));
- (BOOL)setDate:(NSDate *)value forKey:(NSString *)key expireDuration:(uint32_t)seconds NS_SWIFT_NAME(set(_:forKey:expireDuration:));

- (BOOL)setData:(NSData *)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));
- (BOOL)setData:(NSData *)value forKey:(NSString *)key expireDuration:(uint32_t)seconds NS_SWIFT_NAME(set(_:forKey:expireDuration:));

- (nullable id)getObjectOfClass:(Class)cls forKey:(NSString *)key NS_SWIFT_NAME(object(of:forKey:));

- (BOOL)getBoolForKey:(NSString *)key __attribute__((swift_name("bool(forKey:)")));
- (BOOL)getBoolForKey:(NSString *)key defaultValue:(BOOL)defaultValue __attribute__((swift_name("bool(forKey:defaultValue:)")));
- (BOOL)getBoolForKey:(NSString *)key defaultValue:(BOOL)defaultValue hasValue:(KFKV_OUT nullable BOOL *)hasValue __attribute__((swift_name("bool(forKey:defaultValue:hasValue:)")));

- (int32_t)getInt32ForKey:(NSString *)key NS_SWIFT_NAME(int32(forKey:));
- (int32_t)getInt32ForKey:(NSString *)key defaultValue:(int32_t)defaultValue NS_SWIFT_NAME(int32(forKey:defaultValue:));
- (int32_t)getInt32ForKey:(NSString *)key defaultValue:(int32_t)defaultValue hasValue:(KFKV_OUT nullable BOOL *)hasValue NS_SWIFT_NAME(int32(forKey:defaultValue:hasValue:));

- (uint32_t)getUInt32ForKey:(NSString *)key NS_SWIFT_NAME(uint32(forKey:));
- (uint32_t)getUInt32ForKey:(NSString *)key defaultValue:(uint32_t)defaultValue NS_SWIFT_NAME(uint32(forKey:defaultValue:));
- (uint32_t)getUInt32ForKey:(NSString *)key defaultValue:(uint32_t)defaultValue hasValue:(KFKV_OUT nullable BOOL *)hasValue NS_SWIFT_NAME(uint32(forKey:defaultValue:hasValue:));

- (int64_t)getInt64ForKey:(NSString *)key NS_SWIFT_NAME(int64(forKey:));
- (int64_t)getInt64ForKey:(NSString *)key defaultValue:(int64_t)defaultValue NS_SWIFT_NAME(int64(forKey:defaultValue:));
- (int64_t)getInt64ForKey:(NSString *)key defaultValue:(int64_t)defaultValue hasValue:(KFKV_OUT nullable BOOL *)hasValue NS_SWIFT_NAME(int64(forKey:defaultValue:hasValue:));

- (uint64_t)getUInt64ForKey:(NSString *)key NS_SWIFT_NAME(uint64(forKey:));
- (uint64_t)getUInt64ForKey:(NSString *)key defaultValue:(uint64_t)defaultValue NS_SWIFT_NAME(uint64(forKey:defaultValue:));
- (uint64_t)getUInt64ForKey:(NSString *)key defaultValue:(uint64_t)defaultValue hasValue:(KFKV_OUT nullable BOOL *)hasValue NS_SWIFT_NAME(uint64(forKey:defaultValue:hasValue:));

- (float)getFloatForKey:(NSString *)key NS_SWIFT_NAME(float(forKey:));
- (float)getFloatForKey:(NSString *)key defaultValue:(float)defaultValue NS_SWIFT_NAME(float(forKey:defaultValue:));
- (float)getFloatForKey:(NSString *)key defaultValue:(float)defaultValue hasValue:(KFKV_OUT nullable BOOL *)hasValue NS_SWIFT_NAME(float(forKey:defaultValue:hasValue:));

- (double)getDoubleForKey:(NSString *)key NS_SWIFT_NAME(double(forKey:));
- (double)getDoubleForKey:(NSString *)key defaultValue:(double)defaultValue NS_SWIFT_NAME(double(forKey:defaultValue:));
- (double)getDoubleForKey:(NSString *)key defaultValue:(double)defaultValue hasValue:(KFKV_OUT nullable BOOL *)hasValue NS_SWIFT_NAME(double(forKey:defaultValue:hasValue:));

- (nullable NSString *)getStringForKey:(NSString *)key NS_SWIFT_NAME(string(forKey:));
- (nullable NSString *)getStringForKey:(NSString *)key defaultValue:(nullable NSString *)defaultValue NS_SWIFT_NAME(string(forKey:defaultValue:));
- (nullable NSString *)getStringForKey:(NSString *)key defaultValue:(nullable NSString *)defaultValue hasValue:(KFKV_OUT nullable BOOL *)hasValue NS_SWIFT_NAME(string(forKey:defaultValue:hasValue:));

- (nullable NSDate *)getDateForKey:(NSString *)key NS_SWIFT_NAME(date(forKey:));
- (nullable NSDate *)getDateForKey:(NSString *)key defaultValue:(nullable NSDate *)defaultValue NS_SWIFT_NAME(date(forKey:defaultValue:));
- (nullable NSDate *)getDateForKey:(NSString *)key defaultValue:(nullable NSDate *)defaultValue hasValue:(KFKV_OUT nullable BOOL *)hasValue NS_SWIFT_NAME(date(forKey:defaultValue:hasValue:));

- (nullable NSData *)getDataForKey:(NSString *)key NS_SWIFT_NAME(data(forKey:));
- (nullable NSData *)getDataForKey:(NSString *)key defaultValue:(nullable NSData *)defaultValue NS_SWIFT_NAME(data(forKey:defaultValue:));
- (nullable NSData *)getDataForKey:(NSString *)key defaultValue:(nullable NSData *)defaultValue hasValue:(KFKV_OUT nullable BOOL *)hasValue NS_SWIFT_NAME(data(forKey:defaultValue:hasValue:));

// return the actual size consumption of the key's value
// Note: might be a little bigger than value's length
- (size_t)getValueSizeForKey:(NSString *)key actualSize:(BOOL)actualSize NS_SWIFT_NAME(valueSize(forKey:actualSize:));

/// @return size written into buffer
/// @return -1 on any error
- (int32_t)writeValueForKey:(NSString *)key toBuffer:(NSMutableData *)buffer NS_SWIFT_NAME(writeValue(forKey:buffer:));

- (BOOL)containsKey:(NSString *)key NS_SWIFT_NAME(contains(key:));

- (size_t)count;

- (size_t)totalSize;

- (size_t)actualSize;

+ (size_t)pageSize;

+ (NSString *)version;

- (void)enumerateKeys:(void (^)(NSString *key, BOOL *stop))block;
- (NSArray *)allKeys;

/// return count of non-expired keys, keep in mind that it comes with cost
- (size_t)countNonExpiredKeys;

/// return all non-expired keys, keep in mind that it comes with cost
- (NSArray *)allNonExpiredKeys;

/// all keys created (or last modified) longger than expiredInSeconds will be deleted on next full-write-back
/// enableCompareBeforeSet will be invalid when Expiration is on
/// @param expiredInSeconds = KFKVExpireNever (0) means no common expiration duration for all keys, aka each key will have it's own expiration duration
- (BOOL)enableAutoKeyExpire:(uint32_t) expiredInSeconds NS_SWIFT_NAME(enableAutoKeyExpire(expiredInSeconds:));

- (BOOL)disableAutoKeyExpire;

/// Enable data compare before set, for better performance
/// If data for key seldom changes, use it
/// Notice: When encryption or expiration is on, compare-before-set will be invalid.
/// For encryption, compare operation must decrypt data which is time consuming
/// For expiration, compare is useless because in most cases the expiration time changes every time.
- (BOOL)enableCompareBeforeSet;

- (BOOL)disableCompareBeforeSet;

- (void)removeValueForKey:(NSString *)key NS_SWIFT_NAME(removeValue(forKey:));

- (void)removeValuesForKeys:(NSArray<NSString *> *)arrKeys NS_SWIFT_NAME(removeValues(forKeys:));

- (void)clearAllWithKeepingSpace;

- (void)clearAll;

// KFKV's size won't reduce after deleting key-values
// call this method after lots of deleting if you care about disk usage
// note that `clearAll` has the similar effect of `trim`
- (void)trim;

// import all key-value items from source
// return count of items imported
- (size_t)importFrom:(KFKVEngine *)src;

/// call this method if the instance is no longer needed in the near future
/// any subsequent call to the instance is undefined behavior
- (void)close;

/// call this method if you are facing memory-warning
/// any subsequent call to the instance will load all key-values from file again
- (void)clearMemoryCache;

/// enable auto cleanup items that not been accessed recently
/// disable by default
/// note: if an item is strong referenced by outside, it won't be cleanup
+ (void)enableAutoCleanUp:(uint32_t)maxIdleMinutes NS_SWIFT_NAME(enableAutoCleanUp(maxIdleMinutes:));

+ (void)disableAutoCleanUp;

/// you don't need to call this, really, I mean it
/// unless you worry about running out of battery
- (void)sync;
- (void)async;

- (BOOL)isMultiProcess;

- (BOOL)isReadOnly;

#ifdef __cplusplus
- (kfkv::KFKV *)cppInstance;
#endif

/// backup one KFKV instance to dstDir
/// @param mmapID the KFKV ID to backup
/// @param rootPath the customize root path of the KFKV, if null then backup from the root dir of KFKV
/// @param dstDir the backup destination directory
+ (BOOL)backupOneKFKV:(NSString *)mmapID rootPath:(nullable NSString *)rootPath toDirectory:(NSString *)dstDir NS_SWIFT_NAME(backup(mmapID:rootPath:dstDir:));

/// restore one KFKV instance from srcDir
/// @param mmapID the KFKV ID to restore
/// @param rootPath the customize root path of the KFKV, if null then restore to the root dir of KFKV
/// @param srcDir the restore source directory
+ (BOOL)restoreOneKFKV:(NSString *)mmapID rootPath:(nullable NSString *)rootPath fromDirectory:(NSString *)srcDir NS_SWIFT_NAME(restore(mmapID:rootPath:srcDir:));

/// backup all KFKV instance to dstDir
/// @param rootPath the customize root path of the KFKV
/// @param dstDir the backup destination directory
/// @return count of KFKV successfully backuped
+ (size_t)backupAll:(nullable NSString *)rootPath toDirectory:(NSString *)dstDir NS_SWIFT_NAME(backupAll(rootPath:dstDir:));

/// restore all KFKV instance from srcDir
/// @param rootPath the customize root path of the KFKV
/// @param srcDir the restore source directory
/// @return count of KFKV successfully restored
+ (size_t)restoreAll:(nullable NSString *)rootPath fromDirectory:(NSString *)srcDir NS_SWIFT_NAME(restoreAll(rootPath:srcDir:));

/// backup one KFKVMultiProcess KFKV instance to dstDir
/// @param mmapID the KFKV ID to backup
/// @param dstDir the backup destination directory
+ (BOOL)backupMultiProcessKFKV:(NSString *)mmapID toDirectory:(NSString *)dstDir NS_SWIFT_NAME(backupMultiProcess(mmapID:dstDir:));

/// restore one KFKVMultiProcess KFKV instance from srcDir
/// @param mmapID the KFKV ID to restore
/// @param srcDir the restore source directory
+ (BOOL)restoreMultiProcessKFKV:(NSString *)mmapID fromDirectory:(NSString *)srcDir NS_SWIFT_NAME(restoreMultiProcess(mmapID:srcDir:));

/// backup all KFKVMultiProcess KFKV instance to dstDir
/// @param dstDir the backup destination directory
/// @return count of KFKV successfully backuped
+ (size_t)backupAllMultiProcessToDirectory:(NSString *)dstDir NS_SWIFT_NAME(backupAllMultiProcess(dstDir:));

/// restore all KFKVMultiProcess KFKV instance from srcDir
/// @param srcDir the restore source directory
/// @return count of KFKV successfully restored
+ (size_t)restoreAllMultiProcessFromDirectory:(NSString *)srcDir NS_SWIFT_NAME(restoreAllMultiProcess(srcDir:));

/// check if content changed by other process
- (void)checkContentChanged;

+ (void)registerHandler:(id<KFKVHandler>)handler __attribute__((deprecated("use +initializeKFKV:logLevel:handler: instead")));
+ (void)unregiserHandler;

/// KFKVLogInfo by default
/// KFKVLogNone to disable all logging
+ (void)setLogLevel:(KFKVLogLevel)logLevel __attribute__((deprecated("use +initializeKFKV:logLevel: instead", "initializeKFKV:nil logLevel")));

/// Migrate NSUserDefault data to KFKV
/// @param userDaults the dictionaryRepresentation of the NSUserDefaults instance to be imported
/// @return imported count of key-values
- (uint64_t)migrateFromUserDefaultsDictionaryRepresentation:(NSDictionary *)userDaults NS_SWIFT_NAME(migrateFrom(userDefaultsDictionaryRepresentation:));
// use [KFKV migrateFromUserDefaultsDictionaryRepresentation:] instead
- (uint32_t)migrateFromUserDefaults:(id) userDaults NS_SWIFT_NAME(migrateFrom(userDefaults:)) NS_UNAVAILABLE;

/// detect if the KFKV file is valid or not
/// Note: Don't use this to check the existence of the instance, the return value is undefined if the file was never created.
+ (BOOL)isFileValid:(NSString *)mmapID NS_SWIFT_NAME(isFileValid(for:));
+ (BOOL)isFileValid:(NSString *)mmapID rootPath:(nullable NSString *)path NS_SWIFT_NAME(isFileValid(for:rootPath:));

/// remove the storage of the KFKV, including the data file & meta file (.crc)
/// Note: the existing instance (if any) will be closed & destroyed
+ (BOOL)removeStorage:(NSString *)mmapID rootPath:(nullable NSString *)path NS_SWIFT_NAME(removeStorage(for:rootPath:));
+ (BOOL)removeStorage:(NSString *)mmapID mode:(KFKVMode)mode NS_SWIFT_NAME(removeStorage(for:mode:));

/// detect if the KFKV file exist or not
+ (BOOL)checkExist:(NSString *)mmapID rootPath:(nullable NSString *)path NS_SWIFT_NAME(checkExist(for:rootPath:));
+ (BOOL)checkExist:(NSString *)mmapID mode:(KFKVMode)mode NS_SWIFT_NAME(checkExist(for:mode:));

// protection from potential misuse
+ (void)initialize NS_UNAVAILABLE;

@end

@interface KFKVNameSpace : NSObject

- (NSString*)rootPath;

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
- (nullable KFKVEngine *)kfkvWithID:(NSString *)mmapID NS_SWIFT_NAME(kfkv(mmapID:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
- (nullable KFKVEngine *)kfkvWithID:(NSString *)mmapID config:(KFKVConfig)config NS_SWIFT_NAME(init(mmapID:config:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param expectedCapacity the file size you expected when opening or creating file
- (nullable KFKVEngine *)kfkvWithID:(NSString *)mmapID expectedCapacity:(size_t)expectedCapacity NS_SWIFT_NAME(kfkv(mmapID:expectedCapacity:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param mode KFKVReadOnly for readonly KFKV, KFKVMultiProcess for multi-process KFKV
- (nullable KFKVEngine *)kfkvWithID:(NSString *)mmapID mode:(KFKVMode)mode NS_SWIFT_NAME(kfkv(mmapID:mode:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 16 bytes at most
- (nullable KFKVEngine *)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey NS_SWIFT_NAME(kfkv(mmapID:cryptKey:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 32 bytes at most
/// @param aes256 use aes 256 key length
- (nullable KFKVEngine *)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 NS_SWIFT_NAME(kfkv(mmapID:cryptKey:aes256:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 16 bytes at most
/// @param expectedCapacity the file size you expected when opening or creating file
- (nullable KFKVEngine *)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey expectedCapacity:(size_t)expectedCapacity NS_SWIFT_NAME(kfkv(mmapID:cryptKey:expectedCapacity:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 32 bytes at most
/// @param aes256 use aes 256 key length
/// @param expectedCapacity the file size you expected when opening or creating file
- (nullable KFKVEngine *)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 expectedCapacity:(size_t)expectedCapacity NS_SWIFT_NAME(kfkv(mmapID:cryptKey:aes256:expectedCapacity:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 16 bytes at most
/// @param mode KFKVReadOnly for readonly KFKV, KFKVMultiProcess for multi-process KFKV
- (nullable KFKVEngine *)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey mode:(KFKVMode)mode NS_SWIFT_NAME(kfkv(mmapID:cryptKey:mode:));

/// @param mmapID any unique ID (com.tencent.xin.pay, etc), if you want a per-user kfkv, you could merge user-id within mmapID
/// @param cryptKey 32 bytes at most
/// @param aes256 use aes 256 key length
/// @param mode KFKVReadOnly for readonly KFKV, KFKVMultiProcess for multi-process KFKV
- (nullable KFKVEngine *)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 mode:(KFKVMode)mode NS_SWIFT_NAME(kfkv(mmapID:cryptKey:aes256:mode:));

/// backup one KFKV instance from the customize root path to dstDir
/// @param mmapID the KFKV ID to backup
/// @param dstDir the backup destination directory
- (BOOL)backupOneKFKV:(NSString *)mmapID toDirectory:(NSString *)dstDir NS_SWIFT_NAME(backup(mmapID:dstDir:));

/// restore one KFKV instance from srcDir to the customize root path
/// @param mmapID the KFKV ID to restore
/// @param srcDir the restore source directory
- (BOOL)restoreOneKFKV:(NSString *)mmapID fromDirectory:(NSString *)srcDir NS_SWIFT_NAME(restore(mmapID:srcDir:));

/// backup all KFKV instance from the customize root path to dstDir
/// @param dstDir the backup destination directory
/// @return count of KFKV successfully backuped
- (size_t)backupAllToDirectory:(NSString *)dstDir NS_SWIFT_NAME(backupAll(dstDir:));

/// restore all KFKV instance from srcDir to the customize root path
/// @param srcDir the restore source directory
/// @return count of KFKV successfully restored
- (size_t)restoreAllFromDirectory:(NSString *)srcDir NS_SWIFT_NAME(restoreAll(srcDir:));

/// detect if the KFKV file is valid or not
/// Note: Don't use this to check the existence of the instance, the return value is undefined if the file was never created.
- (BOOL)isFileValid:(NSString *)mmapID NS_SWIFT_NAME(isFileValid(for:));

/// remove the storage of the KFKV, including the data file & meta file (.crc)
/// Note: the existing instance (if any) will be closed & destroyed
- (BOOL)removeStorage:(NSString *)mmapID NS_SWIFT_NAME(removeStorage(for:));

/// detect if the KFKV file exist or not
- (BOOL)checkExist:(NSString *)mmapID NS_SWIFT_NAME(checkExist(for:));

// protection from potential misuse
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
