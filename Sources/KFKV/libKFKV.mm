
#import "KFKV.h"
#import <KFKVCore/KFKV.h>
#import <KFKVCore/KFKVLog.h>
#import <KFKVCore/ScopedLock.hpp>
#import <KFKVCore/ThreadLock.h>
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>
#import "AutoCleanInfo.hpp"

#if defined(KFKV_IOS) && !defined(KFKV_IOS_EXTENSION) && !(TARGET_OS_MACCATALYST)
#import <UIKit/UIKit.h>
#endif

using namespace std;

static NSMutableDictionary *g_instanceDic = nil;
static kfkv::ThreadLock *g_lock;
static id<KFKVHandler> g_callbackHandler = nil;
static bool g_isLogRedirecting = false;
static NSString *g_basePath = nil;
static NSString *g_groupPath = nil;

#if defined(KFKV_IOS) && !defined(KFKV_IOS_EXTENSION) && !(TARGET_OS_MACCATALYST)
static BOOL g_isRunningInAppExtension = NO;
#endif

#pragma makr - callbacks

// C++ adapter class that bridges kfkv::KFKVHandler to Objective-C KFKVHandler protocol
class ObjCKFKVHandler : public kfkv::KFKVHandler {
public:
    void kfkvLog(kfkv::KFKVLogLevel level, const char *file, int line, const char *function, KFKVLog_t message) override {
        if (g_callbackHandler && [g_callbackHandler respondsToSelector:@selector(kfkvLogWithLevel:file:line:func:message:)]) {
            [g_callbackHandler kfkvLogWithLevel:(KFKVLogLevel) level file:file line:line func:function message:message];
        }
    }

    kfkv::KFKVRecoverStrategic onKFKVCRCCheckFail(const std::string &mmapID) override {
        if ([g_callbackHandler respondsToSelector:@selector(onKFKVCRCCheckFail:)]) {
            auto ret = [g_callbackHandler onKFKVCRCCheckFail:[NSString stringWithUTF8String:mmapID.c_str()]];
            return (kfkv::KFKVRecoverStrategic) ret;
        }
        return kfkv::OnErrorDiscard;
    }

    kfkv::KFKVRecoverStrategic onKFKVFileLengthError(const std::string &mmapID) override {
        if ([g_callbackHandler respondsToSelector:@selector(onKFKVFileLengthError:)]) {
            auto ret = [g_callbackHandler onKFKVFileLengthError:[NSString stringWithUTF8String:mmapID.c_str()]];
            return (kfkv::KFKVRecoverStrategic) ret;
        }
        return kfkv::OnErrorDiscard;
    }

    void onContentChangedByOuterProcess(const std::string &mmapID) override {
        if ([g_callbackHandler respondsToSelector:@selector(onKFKVContentChange:)]) {
            [g_callbackHandler onKFKVContentChange:[NSString stringWithUTF8String:mmapID.c_str()]];
        }
    }

    void onKFKVContentLoadSuccessfully(const std::string &mmapID) override {
        if ([g_callbackHandler respondsToSelector:@selector(onKFKVContentLoadSuccessfully:)]) {
            [g_callbackHandler onKFKVContentLoadSuccessfully:[NSString stringWithUTF8String:mmapID.c_str()]];
        }
    }
};

static ObjCKFKVHandler g_cppHandler;

@interface KFKVNameSpace ()

- (instancetype) initWith:(NSString *)path;

@end

@implementation KFKVEngine {
    NSString *m_mmapID;
    NSString *m_mmapKey;
    kfkv::KFKV *m_kfkv;
    uint64_t m_lastAccessTime;
}

#pragma mark - init

+ (NSString *)initializeKFKV:(nullable NSString *)rootDir {
    return [KFKVEngine initializeKFKV:rootDir logLevel:KFKVLogInfo handler:nil];
}

+ (NSString *)initializeKFKV:(nullable NSString *)rootDir logLevel:(KFKVLogLevel)logLevel {
    return [KFKVEngine initializeKFKV:rootDir logLevel:logLevel handler:nil];
}

+ (void)initialize {
    if (self == KFKVEngine.class) {
        g_instanceDic = [[NSMutableDictionary alloc] init];
        g_lock = new kfkv::ThreadLock();
        g_lock->initialize();
    }
}

static BOOL g_hasCalledInitializeKFKV = NO;

+ (NSString *)initializeKFKV:(nullable NSString *)rootDir logLevel:(KFKVLogLevel)logLevel handler:(id<KFKVHandler>)handler {
    if (g_hasCalledInitializeKFKV) {
        KFKVWarning("already called +initializeKFKV before, ignore this request");
        return [self kfkvBasePath];
    }
    g_callbackHandler = handler;
    kfkv::KFKVHandler *cppHandler = nullptr;
    if (g_callbackHandler) {
        if ([g_callbackHandler respondsToSelector:@selector(kfkvLogWithLevel:file:line:func:message:)]) {
            g_isLogRedirecting = true;
        }
        cppHandler = &g_cppHandler;
    }

    if (rootDir != nil) {
        g_basePath = rootDir;
    } else {
        [self kfkvBasePath];
    }
    NSAssert(g_basePath.length > 0, @"KFKVEngine not initialized properly, must not call +initializeKFKV: before -application:didFinishLaunchingWithOptions:");
    kfkv::KFKV::initializeKFKV(g_basePath.UTF8String, (kfkv::KFKVLogLevel) logLevel, cppHandler);

    if (g_callbackHandler) {
        kfkv::KFKV::registerHandler(&g_cppHandler);
    }
    
#if defined(KFKV_IOS) && !defined(KFKV_IOS_EXTENSION) && !(TARGET_OS_MACCATALYST)
    // just in case someone forget to set the KFKV_IOS_EXTENSION macro
    if ([[[NSBundle mainBundle] bundlePath] hasSuffix:@".appex"]) {
        g_isRunningInAppExtension = YES;
    }
    if (!g_isRunningInAppExtension) {
        __block auto appState = UIApplicationStateActive;
        if ([NSThread isMainThread]) {
            appState = [UIApplication sharedApplication].applicationState;
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                appState = [UIApplication sharedApplication].applicationState;
            });
        }
        auto isInBackground = (appState == UIApplicationStateBackground);
        kfkv::KFKV::setIsInBackground(isInBackground);
        KFKVInfo("appState:%ld", (long) appState);

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
#endif

    g_hasCalledInitializeKFKV = YES;

    return [self kfkvBasePath];
}

+ (NSString *)initializeKFKV:(nullable NSString *)rootDir groupDir:(NSString *)groupDir logLevel:(KFKVLogLevel)logLevel {
    auto ret = [KFKVEngine initializeKFKV:rootDir logLevel:logLevel handler:nil];

    g_groupPath = [groupDir stringByAppendingPathComponent:@"kfkv"];
    KFKVInfo("groupDir: %@", g_groupPath);

    return ret;
}

+ (NSString *)initializeKFKV:(nullable NSString *)rootDir groupDir:(NSString *)groupDir logLevel:(KFKVLogLevel)logLevel handler:(nullable id<KFKVHandler>)handler {
    auto ret = [KFKVEngine initializeKFKV:rootDir logLevel:logLevel handler:handler];

    g_groupPath = [groupDir stringByAppendingPathComponent:@"kfkv"];
    KFKVInfo("groupDir: %@", g_groupPath);

    return ret;
}

// a generic purpose instance
+ (instancetype)defaultKFKV {
    return [KFKVEngine kfkvWithID:(@"" DEFAULT_MMAP_ID) cryptKey:nil aes256:NO rootPath:nil mode:KFKVSingleProcess expectedCapacity:0];
}

+ (nullable instancetype)defaultKFKVWithConfig:(KFKVConfig)config {
    return [KFKVEngine kfkvWithID:(@"" DEFAULT_MMAP_ID) config:config];
}

+ (nullable instancetype)defaultKFKVWithCryptKey:(nullable NSData *)cryptKey {
    return [KFKVEngine kfkvWithID:(@"" DEFAULT_MMAP_ID) cryptKey:cryptKey aes256:NO rootPath:nil mode:KFKVSingleProcess expectedCapacity:0];
}

+ (nullable instancetype)defaultKFKVWithCryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 {
    return [KFKVEngine kfkvWithID:(@"" DEFAULT_MMAP_ID) cryptKey:cryptKey aes256:aes256 rootPath:nil mode:KFKVSingleProcess expectedCapacity:0];
}

// any unique ID (com.tencent.xin.pay, etc)
+ (instancetype)kfkvWithID:(NSString *)mmapID {
    return [KFKVEngine kfkvWithID:mmapID cryptKey:nil aes256:NO rootPath:nil mode:KFKVSingleProcess expectedCapacity:0];
}

+ (nullable instancetype)kfkvWithID:(NSString *)mmapID config:(KFKVConfig)config {
    if (config.rootPath == nil) {
        if (config.mode & KFKVMultiProcess) {
            config.rootPath = g_groupPath;
        }
    }
    return [KFKVEngine doGetWithID:mmapID config:config];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID expectedCapacity:(size_t)expectedCapacity {
    return [KFKVEngine kfkvWithID:mmapID
                   cryptKey:nil
                     aes256:NO
                   rootPath:nil
                       mode:KFKVSingleProcess
           expectedCapacity:expectedCapacity];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID mode:(KFKVMode)mode {
    auto rootPath = (mode & KFKVSingleProcess) ? nil : g_groupPath;
    return [KFKVEngine kfkvWithID:mmapID cryptKey:nil aes256:NO rootPath:rootPath mode:mode expectedCapacity:0];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(NSData *)cryptKey {
    return [KFKVEngine kfkvWithID:mmapID cryptKey:cryptKey aes256:NO rootPath:nil mode:KFKVSingleProcess expectedCapacity:0];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(NSData *)cryptKey aes256:(BOOL)aes256 {
    return [KFKVEngine kfkvWithID:mmapID cryptKey:cryptKey aes256:aes256 rootPath:nil mode:KFKVSingleProcess expectedCapacity:0];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(NSData *)cryptKey expectedCapacity:(size_t)expectedCapacity {
    return [KFKVEngine kfkvWithID:mmapID cryptKey:cryptKey aes256:NO rootPath:nil mode:KFKVSingleProcess expectedCapacity:expectedCapacity];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(NSData *)cryptKey aes256:(BOOL)aes256 expectedCapacity:(size_t)expectedCapacity {
    return [KFKVEngine kfkvWithID:mmapID cryptKey:cryptKey aes256:aes256 rootPath:nil mode:KFKVSingleProcess expectedCapacity:expectedCapacity];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey mode:(KFKVMode)mode {
    auto rootPath = (mode & KFKVSingleProcess) ? nil : g_groupPath;
    return [KFKVEngine kfkvWithID:mmapID cryptKey:cryptKey aes256:NO rootPath:rootPath mode:mode expectedCapacity:0];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 mode:(KFKVMode)mode {
    auto rootPath = (mode & KFKVSingleProcess) ? nil : g_groupPath;
    return [KFKVEngine kfkvWithID:mmapID cryptKey:cryptKey aes256:aes256 rootPath:rootPath mode:mode expectedCapacity:0];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID rootPath:(nullable NSString *)rootPath {
    return [KFKVEngine kfkvWithID:mmapID cryptKey:nil aes256:NO rootPath:rootPath mode:KFKVSingleProcess expectedCapacity:0];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID rootPath:(nullable NSString *)rootPath expectedCapacity:(size_t)expectedCapacity {
    return [KFKVEngine kfkvWithID:mmapID cryptKey:nil aes256:NO rootPath:rootPath mode:KFKVSingleProcess expectedCapacity:expectedCapacity];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(NSData *)cryptKey rootPath:(nullable NSString *)rootPath {
    return [KFKVEngine kfkvWithID:mmapID cryptKey:cryptKey aes256:NO rootPath:rootPath mode:KFKVSingleProcess expectedCapacity:0];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(NSData *)cryptKey aes256:(BOOL)aes256 rootPath:(nullable NSString *)rootPath {
    return [KFKVEngine kfkvWithID:mmapID cryptKey:cryptKey aes256:aes256 rootPath:rootPath mode:KFKVSingleProcess expectedCapacity:0];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(nullable NSData *)cryptKey rootPath:(nullable NSString *)rootPath expectedCapacity:(size_t)expectedCapacity {
    return [KFKVEngine kfkvWithID:mmapID cryptKey:cryptKey aes256:NO rootPath:rootPath mode:KFKVSingleProcess expectedCapacity:expectedCapacity];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(NSData *)cryptKey rootPath:(nullable NSString *)rootPath mode:(KFKVMode)mode {
    return [KFKVEngine kfkvWithID:mmapID cryptKey:cryptKey aes256:NO rootPath:rootPath mode:mode expectedCapacity:0];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(NSData *)cryptKey rootPath:(nullable NSString *)rootPath mode:(KFKVMode)mode expectedCapacity:(size_t)expectedCapacity {
    return [KFKVEngine kfkvWithID:mmapID cryptKey:cryptKey aes256:NO rootPath:rootPath mode:mode expectedCapacity:expectedCapacity];
}

+ (instancetype)kfkvWithID:(NSString *)mmapID cryptKey:(NSData *)cryptKey aes256:(BOOL)aes256 rootPath:(nullable NSString *)rootPath mode:(KFKVMode)mode expectedCapacity:(size_t)expectedCapacity {
    NSAssert(g_hasCalledInitializeKFKV, @"KFKVEngine not initialized properly, must call +initializeKFKV: in main thread before calling any other KFKVEngine methods");
    if (mode & KFKVMultiProcess) {
        if (!rootPath) {
            rootPath = g_groupPath;
        }
        if (!rootPath) {
            KFKVError("Getting a multi-process KFKVEngine [%@] without setting groupDir makes no sense", mmapID);
            KFKV_ASSERT(0);
        }
    }
    return [self doGetWithID:mmapID cryptKey:cryptKey aes256:aes256 rootPath:rootPath mode:mode expectedCapacity:expectedCapacity];
}

+ (instancetype)doGetWithID:(NSString *)mmapID cryptKey:(NSData *)cryptKey aes256:(BOOL)aes256 rootPath:(nullable NSString *)rootPath mode:(KFKVMode)mode expectedCapacity:(size_t)expectedCapacity {
    auto config = KFKVConfigDefault();
    config.mode = mode;
    config.aes256 = aes256;
    config.cryptKey = cryptKey;
    config.rootPath = rootPath;
    config.expectedCapacity = expectedCapacity;

    return [KFKVEngine doGetWithID:mmapID config:config];
}

+ (instancetype)doGetWithID:(NSString *)mmapID config:(const KFKVConfig&)config {
    if (mmapID.length <= 0) {
        return nil;
    }
    SCOPED_LOCK(g_lock);

    NSString *kvKey = [KFKVEngine mmapKeyWithMMapID:mmapID rootPath:config.rootPath];
    KFKVEngine *kv = [g_instanceDic objectForKey:kvKey];
    if (kv == nil) {
        kv = [[KFKVEngine alloc] initWithMMapID:mmapID config:config];
        if (!kv->m_kfkv) {
            return nil;
        }
        kv->m_mmapKey = kvKey;
        [g_instanceDic setObject:kv forKey:kvKey];
    }
    kv->m_lastAccessTime = llround([NSDate timeIntervalSinceReferenceDate] * 1000);
    return kv;
}

- (instancetype)initWithMMapID:(NSString *)mmapID config:(const KFKVConfig&)config {
    if (self = [super init]) {
        kfkv::KFKVConfig cppConfig;
        cppConfig.mode = (kfkv::KFKVMode) config.mode;
        cppConfig.aes256 = config.aes256;

        auto rootPath = config.rootPath;
        string pathTmp;
        if (rootPath.length > 0) {
            pathTmp = rootPath.UTF8String;
        }
        string cryptKeyTmp;
        auto cryptKey = config.cryptKey;
        if (cryptKey.length > 0) {
            cryptKeyTmp = string((char *) cryptKey.bytes, cryptKey.length);
        }
        cppConfig.rootPath = pathTmp.empty() ? nullptr : &pathTmp;
        cppConfig.cryptKey = cryptKeyTmp.empty() ? nullptr : &cryptKeyTmp;

        cppConfig.expectedCapacity = config.expectedCapacity;

        if (config.enableKeyExpire != nil) {
            cppConfig.enableKeyExpire = (config.enableKeyExpire.boolValue == YES);
        }
        cppConfig.expiredInSeconds = config.expiredInSeconds;
        cppConfig.enableCompareBeforeSet = (config.enableCompareBeforeSet == YES);

        if (config.recover != KFKVOnErrorNotSet) {
            cppConfig.recover = (kfkv::KFKVRecoverStrategic) config.recover;
        }

        cppConfig.itemSizeLimit = config.itemSizeLimit;

        m_kfkv = kfkv::KFKV::kfkvWithID(mmapID.UTF8String, cppConfig);
        if (!m_kfkv) {
            return self;
        }
        m_mmapID = [[NSString alloc] initWithUTF8String:m_kfkv->mmapID().c_str()];

#if defined(KFKV_IOS) && !defined(KFKV_IOS_EXTENSION) && !(TARGET_OS_MACCATALYST)
        if (!g_isRunningInAppExtension) {
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(onMemoryWarning)
                                                         name:UIApplicationDidReceiveMemoryWarningNotification
                                                       object:nil];
        }
#endif
    }
    return self;
}

- (void)dealloc {
    [self clearMemoryCache];

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    KFKVInfo("dealloc %@", m_mmapID);

    if (m_kfkv) {
        m_kfkv->close();
        m_kfkv = nullptr;
    }
}

- (NSString *)mmapID {
    return m_mmapID;
}

#pragma mark - Application state

#if defined(KFKV_IOS) && !defined(KFKV_IOS_EXTENSION) && !(TARGET_OS_MACCATALYST)
- (void)onMemoryWarning {
    KFKVInfo("cleaning on memory warning %@", m_mmapID);

    [self clearMemoryCache];
}

+ (void)didEnterBackground {
    kfkv::KFKV::setIsInBackground(true);
    KFKVInfo("isInBackground:%d", true);
}

+ (void)didBecomeActive {
    kfkv::KFKV::setIsInBackground(false);
    KFKVInfo("isInBackground:%d", false);
}
#endif

- (void)clearAll {
    m_kfkv->clearAll();
}

- (void)clearAllWithKeepingSpace {
    m_kfkv->clearAll(true);
}

- (void)clearMemoryCache {
    if (m_kfkv) {
        m_kfkv->clearMemoryCache();
    }
}

- (void)close {
    SCOPED_LOCK(g_lock);
    KFKVInfo("closing %@", m_mmapID);

    [g_instanceDic removeObjectForKey:m_mmapKey];

    if (CFGetRetainCount((__bridge CFTypeRef)self) > 1) {
        KFKVWarning("There's still reference on this kv: %@", m_mmapID);
    }
}

- (void)trim {
    m_kfkv->trim();
}

- (size_t)importFrom:(KFKVEngine *)src {
    if (!src) {
        return 0;
    }
    return m_kfkv->importFrom(src->m_kfkv);
}

#pragma mark - encryption & decryption

#ifndef KFKV_DISABLE_CRYPT

- (nullable NSData *)cryptKey {
    auto str = m_kfkv->cryptKey();
    if (str.length() > 0) {
        return [NSData dataWithBytes:str.data() length:str.length()];
    }
    return nil;
}

- (BOOL)reKey:(nullable NSData *)newKey {
    return [self reKey:newKey aes256:NO];
}

- (BOOL)reKey:(nullable NSData *)newKey aes256:(BOOL)aes256 {
    string key;
    if (newKey.length > 0) {
        key = string((char *) newKey.bytes, newKey.length);
    }
    return m_kfkv->reKey(key, aes256);
}

- (void)checkReSetCryptKey:(nullable NSData *)cryptKey {
    [self  checkReSetCryptKey:cryptKey aes256:NO];
}

- (void)checkReSetCryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 {
    if (cryptKey.length > 0) {
        string key = string((char *) cryptKey.bytes, cryptKey.length);
        m_kfkv->checkReSetCryptKey(&key, aes256);
    } else {
        m_kfkv->checkReSetCryptKey(nullptr, aes256);
    }
}

#else

- (nullable NSData *)cryptKey {
    return nil;
}

- (BOOL)reKey:(nullable NSData *)newKey {
    return NO;
}

- (BOOL)reKey:(nullable NSData *)newKey aes256:(BOOL)aes256 {
    return NO;
}

- (void)checkReSetCryptKey:(nullable NSData *)cryptKey {
}

- (void)checkReSetCryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 {
}

#endif // KFKV_DISABLE_CRYPT

#pragma mark - set & get

- (BOOL)setObject:(nullable NSObject<NSCoding> *)object forKey:(NSString *)key {
    return m_kfkv->set(object, key);
}

- (BOOL)setObject:(nullable NSObject<NSCoding> *)object forKey:(NSString *)key expireDuration:(uint32_t)seconds {
    return m_kfkv->set(object, key, seconds);
}

- (BOOL)setBool:(BOOL)value forKey:(NSString *)key {
    return m_kfkv->set((bool) value, key);
}

- (BOOL)setBool:(BOOL)value forKey:(NSString *)key expireDuration:(uint32_t)seconds {
    return m_kfkv->set((bool) value, key, seconds);
}

- (BOOL)setInt32:(int32_t)value forKey:(NSString *)key {
    return m_kfkv->set(value, key);
}

- (BOOL)setInt32:(int32_t)value forKey:(NSString *)key expireDuration:(uint32_t)seconds {
    return m_kfkv->set(value, key, seconds);
}

- (BOOL)setUInt32:(uint32_t)value forKey:(NSString *)key {
    return m_kfkv->set(value, key);
}

- (BOOL)setUInt32:(uint32_t)value forKey:(NSString *)key expireDuration:(uint32_t)seconds {
    return m_kfkv->set(value, key, seconds);
}

- (BOOL)setInt64:(int64_t)value forKey:(NSString *)key {
    return m_kfkv->set(value, key);
}

- (BOOL)setInt64:(int64_t)value forKey:(NSString *)key expireDuration:(uint32_t)seconds {
    return m_kfkv->set(value, key, seconds);
}

- (BOOL)setUInt64:(uint64_t)value forKey:(NSString *)key {
    return m_kfkv->set(value, key);
}

- (BOOL)setUInt64:(uint64_t)value forKey:(NSString *)key expireDuration:(uint32_t)seconds {
    return m_kfkv->set(value, key, seconds);
}

- (BOOL)setFloat:(float)value forKey:(NSString *)key {
    return m_kfkv->set(value, key);
}

- (BOOL)setFloat:(float)value forKey:(NSString *)key expireDuration:(uint32_t)seconds {
    return m_kfkv->set(value, key, seconds);
}

- (BOOL)setDouble:(double)value forKey:(NSString *)key {
    return m_kfkv->set(value, key);
}

- (BOOL)setDouble:(double)value forKey:(NSString *)key expireDuration:(uint32_t)seconds {
    return m_kfkv->set(value, key, seconds);
}

- (BOOL)setString:(NSString *)value forKey:(NSString *)key {
    return [self setObject:value forKey:key];
}

- (BOOL)setString:(NSString *)value forKey:(NSString *)key expireDuration:(uint32_t)seconds {
    return [self setObject:value forKey:key expireDuration:seconds];
}

- (BOOL)setDate:(NSDate *)value forKey:(NSString *)key {
    return [self setObject:value forKey:key];
}

- (BOOL)setDate:(NSDate *)value forKey:(NSString *)key expireDuration:(uint32_t)seconds {
    return [self setObject:value forKey:key expireDuration:seconds];
}

- (BOOL)setData:(NSData *)value forKey:(NSString *)key {
    return [self setObject:value forKey:key];
}

- (BOOL)setData:(NSData *)value forKey:(NSString *)key expireDuration:(uint32_t)seconds {
    return [self setObject:value forKey:key expireDuration:seconds];
}

- (id)getObjectOfClass:(Class)cls forKey:(NSString *)key {
    return m_kfkv->getObject(key, cls);
}

- (BOOL)getBoolForKey:(NSString *)key {
    return [self getBoolForKey:key defaultValue:FALSE hasValue:nil];
}
- (BOOL)getBoolForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    return [self getBoolForKey:key defaultValue:defaultValue hasValue:nil];
}
- (BOOL)getBoolForKey:(NSString *)key defaultValue:(BOOL)defaultValue hasValue:(KFKV_OUT BOOL *)hasValue {
    return m_kfkv->getBool(key, defaultValue, (bool *) hasValue);
}

- (int32_t)getInt32ForKey:(NSString *)key {
    return [self getInt32ForKey:key defaultValue:0 hasValue:nil];
}
- (int32_t)getInt32ForKey:(NSString *)key defaultValue:(int32_t)defaultValue {
    return [self getInt32ForKey:key defaultValue:defaultValue hasValue:nil];
}
- (int32_t)getInt32ForKey:(NSString *)key defaultValue:(int32_t)defaultValue hasValue:(KFKV_OUT BOOL *)hasValue {
    return m_kfkv->getInt32(key, defaultValue, (bool *) hasValue);
}

- (uint32_t)getUInt32ForKey:(NSString *)key {
    return [self getUInt32ForKey:key defaultValue:0 hasValue:nil];
}
- (uint32_t)getUInt32ForKey:(NSString *)key defaultValue:(uint32_t)defaultValue {
    return [self getUInt32ForKey:key defaultValue:defaultValue hasValue:nil];
}
- (uint32_t)getUInt32ForKey:(NSString *)key defaultValue:(uint32_t)defaultValue hasValue:(KFKV_OUT BOOL *)hasValue {
    return m_kfkv->getUInt32(key, defaultValue, (bool *) hasValue);
}

- (int64_t)getInt64ForKey:(NSString *)key {
    return [self getInt64ForKey:key defaultValue:0 hasValue:nil];
}
- (int64_t)getInt64ForKey:(NSString *)key defaultValue:(int64_t)defaultValue {
    return [self getInt64ForKey:key defaultValue:defaultValue hasValue:nil];
}
- (int64_t)getInt64ForKey:(NSString *)key defaultValue:(int64_t)defaultValue hasValue:(KFKV_OUT BOOL *)hasValue {
    return m_kfkv->getInt64(key, defaultValue, (bool *) hasValue);
}

- (uint64_t)getUInt64ForKey:(NSString *)key {
    return [self getUInt64ForKey:key defaultValue:0 hasValue:nil];
}
- (uint64_t)getUInt64ForKey:(NSString *)key defaultValue:(uint64_t)defaultValue {
    return [self getUInt64ForKey:key defaultValue:defaultValue hasValue:nil];
}
- (uint64_t)getUInt64ForKey:(NSString *)key defaultValue:(uint64_t)defaultValue hasValue:(KFKV_OUT BOOL *)hasValue {
    return m_kfkv->getUInt64(key, defaultValue, (bool *) hasValue);
}

- (float)getFloatForKey:(NSString *)key {
    return [self getFloatForKey:key defaultValue:0 hasValue:nil];
}
- (float)getFloatForKey:(NSString *)key defaultValue:(float)defaultValue {
    return [self getFloatForKey:key defaultValue:defaultValue hasValue:nil];
}
- (float)getFloatForKey:(NSString *)key defaultValue:(float)defaultValue hasValue:(KFKV_OUT BOOL *)hasValue {
    return m_kfkv->getFloat(key, defaultValue, (bool *) hasValue);
}

- (double)getDoubleForKey:(NSString *)key {
    return [self getDoubleForKey:key defaultValue:0 hasValue:nil];
}
- (double)getDoubleForKey:(NSString *)key defaultValue:(double)defaultValue {
    return [self getDoubleForKey:key defaultValue:defaultValue hasValue:nil];
}
- (double)getDoubleForKey:(NSString *)key defaultValue:(double)defaultValue hasValue:(KFKV_OUT BOOL *)hasValue {
    return m_kfkv->getDouble(key, defaultValue, (bool *) hasValue);
}

- (nullable NSString *)getStringForKey:(NSString *)key {
    return [self getStringForKey:key defaultValue:nil hasValue:nil];
}
- (nullable NSString *)getStringForKey:(NSString *)key defaultValue:(nullable NSString *)defaultValue {
    return [self getStringForKey:key defaultValue:defaultValue hasValue:nil];
}
- (nullable NSString *)getStringForKey:(NSString *)key defaultValue:(nullable NSString *)defaultValue hasValue:(KFKV_OUT BOOL *)hasValue {
    if (key.length <= 0) {
        return defaultValue;
    }
    NSString *valueString = [self getObjectOfClass:NSString.class forKey:key];
    if (!valueString) {
        if (hasValue != nil) {
            *hasValue = false;
        }
        valueString = defaultValue;
    }
    return valueString;
}

- (nullable NSDate *)getDateForKey:(NSString *)key {
    return [self getDateForKey:key defaultValue:nil hasValue:nil];
}
- (nullable NSDate *)getDateForKey:(NSString *)key defaultValue:(nullable NSDate *)defaultValue {
    return [self getDateForKey:key defaultValue:defaultValue hasValue:nil];
}
- (nullable NSDate *)getDateForKey:(NSString *)key defaultValue:(nullable NSDate *)defaultValue hasValue:(KFKV_OUT BOOL *)hasValue {
    if (key.length <= 0) {
        return defaultValue;
    }
    NSDate *valueDate = [self getObjectOfClass:NSDate.class forKey:key];
    if (!valueDate) {
        if (hasValue != nil) {
            *hasValue = false;
        }
        valueDate = defaultValue;
    }
    return valueDate;
}

- (nullable NSData *)getDataForKey:(NSString *)key {
    return [self getDataForKey:key defaultValue:nil];
}
- (nullable NSData *)getDataForKey:(NSString *)key defaultValue:(nullable NSData *)defaultValue {
    return [self getDataForKey:key defaultValue:defaultValue hasValue:nil];
}
- (nullable NSData *)getDataForKey:(NSString *)key defaultValue:(nullable NSData *)defaultValue hasValue:(KFKV_OUT BOOL *)hasValue {
    if (key.length <= 0) {
        return defaultValue;
    }
    NSData *valueData = [self getObjectOfClass:NSData.class forKey:key];
    if (!valueData) {
        if (hasValue != nil) {
            *hasValue = false;
        }
        valueData = defaultValue;
    }
    return valueData;
}

- (size_t)getValueSizeForKey:(NSString *)key actualSize:(BOOL)actualSize {
    return m_kfkv->getValueSize(key, actualSize);
}

- (int32_t)writeValueForKey:(NSString *)key toBuffer:(NSMutableData *)buffer {
    return m_kfkv->writeValueToBuffer(key, buffer.mutableBytes, static_cast<int32_t>(buffer.length));
}

#pragma mark - enumerate

- (BOOL)containsKey:(NSString *)key {
    return m_kfkv->containsKey(key);
}

- (size_t)count {
    return m_kfkv->count();
}

- (size_t)totalSize {
    return m_kfkv->totalSize();
}

- (size_t)actualSize {
    return m_kfkv->actualSize();
}

+ (size_t)pageSize {
    return kfkv::DEFAULT_MMAP_SIZE;
}

+ (NSString *)version {
    return [NSString stringWithCString:KFKV_VERSION encoding:NSASCIIStringEncoding];
}

- (void)enumerateKeys:(void (^)(NSString *key, BOOL *stop))block {
    m_kfkv->enumerateKeys(block);
}

- (NSArray *)allKeys {
    return m_kfkv->allKeysObjC();
}

- (size_t)countNonExpiredKeys {
    return m_kfkv->count(true);
}

- (NSArray *)allNonExpiredKeys {
    return m_kfkv->allKeysObjC(true);
}

- (BOOL)enableAutoKeyExpire:(uint32_t)expiredInSeconds {
    if (m_kfkv->isCompareBeforeSetEnabled()) {
        KFKVWarning("enableCompareBeforeSet will be invalid when Expiration is on");
#if DEBUG
        KFKV_ASSERT(0);
#endif
    }
    return m_kfkv->enableAutoKeyExpire(expiredInSeconds);
}

- (BOOL)disableAutoKeyExpire {
    return m_kfkv->disableAutoKeyExpire();
}

- (BOOL)enableCompareBeforeSet {
    if (m_kfkv->isExpirationEnabled()) {
        KFKVWarning("enableCompareBeforeSet is invalid when Expiration is on");
#if DEBUG
        KFKV_ASSERT(0);
#endif
        return NO;
    }
    if (m_kfkv->isEncryptionEnabled()) {
        KFKVWarning("enableCompareBeforeSet is invalid when key encryption is on");
#if DEBUG
        KFKV_ASSERT(0);
#endif
        return NO;
    }

    return m_kfkv->enableCompareBeforeSet();
}

- (BOOL)disableCompareBeforeSet {
    return m_kfkv->disableCompareBeforeSet();
}

- (void)removeValueForKey:(NSString *)key {
    m_kfkv->removeValueForKey(key);
}

- (void)removeValuesForKeys:(NSArray *)arrKeys {
    m_kfkv->removeValuesForKeys(arrKeys);
}

- (void)sync {
    m_kfkv->sync(kfkv::KFKV_SYNC);
}

- (void)async {
    m_kfkv->sync(kfkv::KFKV_ASYNC);
}

- (void)checkContentChanged {
    m_kfkv->checkContentChanged();
}

- (BOOL)isMultiProcess {
    return m_kfkv->isMultiProcess();
}

- (BOOL)isReadOnly {
    return m_kfkv->isReadOnly();
}

- (kfkv::KFKV *)cppInstance {
    return m_kfkv;
}

+ (void)onAppTerminate {
    g_lock->lock();

    // make sure no further call will go into m_kfkv
    [g_instanceDic enumerateKeysAndObjectsUsingBlock:^(id _Nonnull key, KFKVEngine *_Nonnull kfkv, BOOL *_Nonnull stop) {
        kfkv->m_kfkv = nullptr;
    }];
    g_instanceDic = nil;

    g_basePath = nil;

    g_groupPath = nil;

    kfkv::KFKV::onExit();

    g_lock->unlock();
    delete g_lock;
    g_lock = nullptr;
}

static bool g_isAutoCleanUpEnabled = false;
static uint32_t g_maxIdleMS = 0;
constexpr int DoCleanUpDurationMS = 2 * 1000;
static dispatch_source_t g_autoCleanUpTimer = nullptr;
static AutoCleanInfoQueue_t g_cleanQueue = {};

+ (void)enableAutoCleanUp:(uint32_t)maxIdleMinutes {
    KFKVInfo("enable auto clean up with maxIdleMinutes:%zu", maxIdleMinutes);
    SCOPED_LOCK(g_lock);

    g_isAutoCleanUpEnabled = true;
    g_maxIdleMS = maxIdleMinutes * 60 * 1000;

    if (!g_autoCleanUpTimer) {
        g_autoCleanUpTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        dispatch_source_set_event_handler(g_autoCleanUpTimer, ^{
            [KFKVEngine tryAutoCleanUpInstances];
        });
    } else {
        dispatch_suspend(g_autoCleanUpTimer);
    }
    dispatch_source_set_timer(g_autoCleanUpTimer,
                              dispatch_time(DISPATCH_TIME_NOW, g_maxIdleMS * NSEC_PER_MSEC),
                              g_maxIdleMS * NSEC_PER_MSEC,
                              0);
    dispatch_resume(g_autoCleanUpTimer);
}

+ (void)disableAutoCleanUp {
    KFKVInfo("disable auto clean up");
    SCOPED_LOCK(g_lock);

    g_isAutoCleanUpEnabled = false;
    g_maxIdleMS = 0;

    if (g_autoCleanUpTimer) {
        dispatch_source_cancel(g_autoCleanUpTimer);
        g_autoCleanUpTimer = nullptr;
    }
}

/// clean up kfkv instance that not been access lately
///   There are two phases of auto clean:
///   1. check-cleanup phase with longer duration: CleanUpDurationMS
///   2. do-cleanup phase with faster duration: DoCleanUpDurationSecends
+ (void)tryAutoCleanUpInstances {
    SCOPED_LOCK(g_lock);

#if defined(KFKV_IOS) && !(TARGET_OS_MACCATALYST)
    if (kfkv::KFKV::isInBackground()) {
        KFKVInfo("don't cleanup in background, might just wakeup from suspend");
        return;
    }
#endif

    const uint64_t now = llround([NSDate timeIntervalSinceReferenceDate] * 1000);

    // mark that we were once in do-cleanup phase and maybe needs reset timer
    bool inDoCleanupPhase = !g_cleanQueue.empty();
    while (!g_cleanQueue.empty()) {
        auto &info = g_cleanQueue.top();
        auto kfkv = (KFKVEngine *) [g_instanceDic objectForKey:info.m_key];
        if (kfkv) {
            if (kfkv->m_kfkv->try_lock_thread()) {
                // check m_lastAccessTime again
                if ((kfkv->m_lastAccessTime) + g_maxIdleMS <= now && (CFGetRetainCount((__bridge CFTypeRef)kfkv)) == 1) {
                    // clean one at a time, prevent from holding g_lock for too long
                    @autoreleasepool {
                        KFKVInfo("auto cleanup kfkv [%@], m_time: %llu", info.m_key, info.m_time);
                        [g_instanceDic removeObjectForKey:info.m_key];
                        g_cleanQueue.pop();
                        // enumerate & check again if hit the bottom
                        if (g_cleanQueue.empty()) {
                            break;
                        }
                        return;
                    }
                }
                KFKVInfo("ignore auto cleanup kfkv [%@], m_lastAccessTime: %llu", info.m_key, (kfkv->m_lastAccessTime));
                kfkv->m_kfkv->unlock_thread();
            }
            // if we reach here, it's must have been access by someone, ignore it
            g_cleanQueue.pop();
        } else {
            // someone else has closed it
            KFKVInfo("ignore already closed kfkv [%@]", info.m_key);
            g_cleanQueue.pop();
        }
    }

    [g_instanceDic enumerateKeysAndObjectsUsingBlock:^(id _Nonnull key, id _Nonnull obj, BOOL *_Nonnull stop) {
        auto kfkv = (KFKVEngine *) obj;
        if ((kfkv->m_lastAccessTime) + g_maxIdleMS <= now && (CFGetRetainCount((__bridge CFTypeRef)kfkv)) == 1) {
            KFKVInfo("adding to cleanup queue kfkv [%@], m_lastAccessTime: %llu", key, (kfkv->m_lastAccessTime));
            g_cleanQueue.emplace((NSString *) key, (kfkv->m_lastAccessTime));
        }
    }];

    if (g_autoCleanUpTimer) {
        if (!inDoCleanupPhase && !g_cleanQueue.empty()) {
            KFKVInfo("switch to do-cleanup phase with faster duration");
            dispatch_source_set_timer(g_autoCleanUpTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, DoCleanUpDurationMS * NSEC_PER_MSEC),
                                      DoCleanUpDurationMS * NSEC_PER_MSEC,
                                      60 * NSEC_PER_SEC);
        } else if (inDoCleanupPhase && g_cleanQueue.empty()) {
            KFKVInfo("switch back to check-cleanup phase with longer duration");
            dispatch_source_set_timer(g_autoCleanUpTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, g_maxIdleMS * NSEC_PER_MSEC),
                                      g_maxIdleMS * NSEC_PER_MSEC,
                                      60 * NSEC_PER_SEC);
        }
    }
}

+ (NSString *)kfkvBasePath {
    if (g_basePath.length > 0) {
        return g_basePath;
    }

#if TARGET_OS_TV
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
#else
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
#endif
    NSString *documentPath = (NSString *) [paths firstObject];
    if ([documentPath length] > 0) {
        g_basePath = [documentPath stringByAppendingPathComponent:@"kfkv"];
        return g_basePath;
    } else {
        return @"";
    }
}

+ (void)setKFKVBasePath:(NSString *)basePath {
    if (basePath.length > 0) {
        g_basePath = basePath;
        [KFKVEngine initializeKFKV:basePath];

        // still warn about it
        g_hasCalledInitializeKFKV = NO;

        KFKVInfo("set KFKVEngine base path to: %@", g_basePath);
    }
}

+ (NSString *)kfkvGroupPath {
    return g_groupPath;
}

- (void)setValue:(nullable id)value forKey:(NSString *)key {
    [super setValue:value forKey:key];
}

- (void)setValue:(nullable id)value forKeyPath:(NSString *)keyPath {
    [super setValue:value forKeyPath:keyPath];
}

static NSString *md5(NSString *value) {
    uint8_t md[CC_MD5_DIGEST_LENGTH] = {};
    char tmp[3] = {}, buf[33] = {};
    auto data = [value dataUsingEncoding:NSUTF8StringEncoding];
    CC_MD5((uint8_t *) data.bytes, data.length, md);
    for (auto ch : md) {
        snprintf(tmp, sizeof(tmp), "%2.2x", ch);
        strcat(buf, tmp);
    }
    return [NSString stringWithCString:buf encoding:NSASCIIStringEncoding];
}

+ (NSString *)mmapKeyWithMMapID:(NSString *)mmapID rootPath:(nullable NSString *)rootPath {
    NSString *string = nil;
    if ([rootPath length] > 0 && [rootPath isEqualToString:[KFKVEngine kfkvBasePath]] == NO) {
        string = md5([rootPath stringByAppendingPathComponent:mmapID]);
    } else {
        string = mmapID;
    }
    KFKVDebug("mmapKey: %@", string);
    return string;
}

+ (BOOL)isFileValid:(NSString *)mmapID {
    return [self isFileValid:mmapID rootPath:nil];
}

+ (BOOL)isFileValid:(NSString *)mmapID rootPath:(nullable NSString *)path {
    if (mmapID.length > 0) {
        if (path.length > 0) {
            string rootPath(path.UTF8String);
            return kfkv::KFKV::isFileValid(mmapID.UTF8String, &rootPath);
        } else {
            return kfkv::KFKV::isFileValid(mmapID.UTF8String, nullptr);
        }
    }
    return NO;
}

#pragma mark - backup & restore

+ (BOOL)backupOneKFKV:(NSString *)mmapID rootPath:(nullable NSString *)path toDirectory:(NSString *)dstDir {
    if (path.length > 0) {
        string rootPath(path.UTF8String);
        return kfkv::KFKV::backupOneToDirectory(mmapID.UTF8String, dstDir.UTF8String, &rootPath);
    }
    return kfkv::KFKV::backupOneToDirectory(mmapID.UTF8String, dstDir.UTF8String);
}

+ (BOOL)restoreOneKFKV:(NSString *)mmapID rootPath:(nullable NSString *)path fromDirectory:(NSString *)srcDir {
    if (path.length > 0) {
        string rootPath(path.UTF8String);
        return kfkv::KFKV::restoreOneFromDirectory(mmapID.UTF8String, srcDir.UTF8String, &rootPath);
    }
    return kfkv::KFKV::restoreOneFromDirectory(mmapID.UTF8String, srcDir.UTF8String);
}

+ (size_t)backupAll:(nullable NSString *)path toDirectory:(NSString *)dstDir {
    if (path.length > 0) {
        string rootPath(path.UTF8String);
        return kfkv::KFKV::backupAllToDirectory(dstDir.UTF8String, &rootPath);
    }
    return kfkv::KFKV::backupAllToDirectory(dstDir.UTF8String);
}

+ (size_t)restoreAll:(nullable NSString *)path fromDirectory:(NSString *)srcDir {
    if (path.length > 0) {
        string rootPath(path.UTF8String);
        return kfkv::KFKV::restoreAllFromDirectory(srcDir.UTF8String, &rootPath);
    }
    return kfkv::KFKV::restoreAllFromDirectory(srcDir.UTF8String);
}

+ (BOOL)backupMultiProcessKFKV:(NSString *)mmapID toDirectory:(NSString *)dstDir {
    if (!g_groupPath) {
        KFKVError("Backup a multi-process KFKVEngine [%@] without setting groupDir makes no sense", mmapID);
        KFKV_ASSERT(0);
    }
    return [KFKVEngine backupOneKFKV:mmapID rootPath:g_groupPath toDirectory:dstDir];
}

+ (BOOL)restoreMultiProcessKFKV:(NSString *)mmapID fromDirectory:(NSString *)srcDir {
    if (!g_groupPath) {
        KFKVError("Restore a multi-process KFKVEngine [%@] without setting groupDir makes no sense", mmapID);
        KFKV_ASSERT(0);
    }
    return [KFKVEngine restoreOneKFKV:mmapID rootPath:g_groupPath fromDirectory:srcDir];
}

+ (size_t)backupAllMultiProcessToDirectory:(NSString *)dstDir {
    if (!g_groupPath) {
        KFKVError("Backup multi-process KFKVEngine without setting groupDir makes no sense.");
        KFKV_ASSERT(0);
    }
    return [KFKVEngine backupAll:g_groupPath toDirectory:dstDir];
}

+ (size_t)restoreAllMultiProcessFromDirectory:(NSString *)srcDir {
    if (!g_groupPath) {
        KFKVError("Restore multi-process KFKVEngine without setting groupDir makes no sense.");
        KFKV_ASSERT(0);
    }
    return [KFKVEngine restoreAll:g_groupPath fromDirectory:srcDir];
}

#pragma mark - handler

+ (void)registerHandler:(id<KFKVHandler>)handler {
    SCOPED_LOCK(g_lock);
    g_callbackHandler = handler;

    if (g_callbackHandler) {
        if ([g_callbackHandler respondsToSelector:@selector(kfkvLogWithLevel:file:line:func:message:)]) {
            g_isLogRedirecting = true;
        }
        kfkv::KFKV::registerHandler(&g_cppHandler);
    } else {
        g_isLogRedirecting = false;
        kfkv::KFKV::unRegisterHandler();
    }
}

+ (void)unregiserHandler {
    SCOPED_LOCK(g_lock);

    g_isLogRedirecting = false;
    g_callbackHandler = nil;

    kfkv::KFKV::unRegisterHandler();
}

+ (void)setLogLevel:(KFKVLogLevel)logLevel {
    kfkv::KFKV::setLogLevel((kfkv::KFKVLogLevel) logLevel);
}

- (uint64_t)migrateFromUserDefaultsDictionaryRepresentation:(NSDictionary *)dic {
    if (dic.count <= 0) {
        KFKVInfo("migrate data fail, dic is nil or empty");
        return 0;
    }
    @autoreleasepool {
        __block uint64_t count = 0;
        [dic enumerateKeysAndObjectsUsingBlock:^(id _Nonnull key, id _Nonnull obj, BOOL *_Nonnull stop) {
            if ([key isKindOfClass:[NSString class]]) {
                NSString *stringKey = key;
                if ([KFKVEngine tranlateData:obj key:stringKey kv:self]) {
                    count++;
                }
            } else {
                KFKVWarning("unknown type of key:%@", key);
            }
        }];
        return count;
    }
}

+ (BOOL)tranlateData:(id)obj key:(NSString *)key kv:(KFKVEngine *)kv {
    if ([obj isKindOfClass:[NSString class]]) {
        return [kv setString:obj forKey:key];
    } else if ([obj isKindOfClass:[NSData class]]) {
        return [kv setData:obj forKey:key];
    } else if ([obj isKindOfClass:[NSDate class]]) {
        return [kv setDate:obj forKey:key];
    } else if ([obj isKindOfClass:[NSNumber class]]) {
        NSNumber *num = obj;
        CFNumberType numberType = CFNumberGetType((CFNumberRef) obj);
        switch (numberType) {
            case kCFNumberCharType:
            case kCFNumberSInt8Type:
            case kCFNumberSInt16Type:
            case kCFNumberSInt32Type:
            case kCFNumberIntType:
            case kCFNumberShortType:
                return [kv setInt32:num.intValue forKey:key];
            case kCFNumberSInt64Type:
            case kCFNumberLongType:
            case kCFNumberNSIntegerType:
            case kCFNumberLongLongType:
                return [kv setInt64:num.longLongValue forKey:key];
            case kCFNumberFloat32Type:
                return [kv setFloat:num.floatValue forKey:key];
            case kCFNumberFloat64Type:
            case kCFNumberDoubleType:
                return [kv setDouble:num.doubleValue forKey:key];
            default:
                KFKVWarning("unknown number type:%ld, key:%@", (long) numberType, key);
                return NO;
        }
    } else if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSDictionary class]]) {
        return [kv setObject:obj forKey:key];
    } else {
        KFKVWarning("unknown type of key:%@", key);
    }
    return NO;
}

+ (BOOL)removeStorage:(NSString *)mmapID rootPath:(nullable NSString *)path NS_SWIFT_NAME(removeStorage(for:rootPath:)) {
    SCOPED_LOCK(g_lock);
    NSString *kvKey = [KFKVEngine mmapKeyWithMMapID:mmapID rootPath:path];
    KFKVEngine *kv = [g_instanceDic objectForKey:kvKey];
    if (kv != nil) {
        [g_instanceDic removeObjectForKey:kvKey];
        if (CFGetRetainCount((__bridge CFTypeRef)kv) > 1) {
            KFKVWarning("There's still reference on this kv: %@", mmapID);
            // we can't wait for dealloc
            kv->m_kfkv = nullptr;
        }
    }

    if (mmapID.length > 0) {
        if (path.length > 0) {
            string rootPath(path.UTF8String);
            return kfkv::KFKV::removeStorage(mmapID.UTF8String, &rootPath);
        } else {
            return kfkv::KFKV::removeStorage(mmapID.UTF8String, nullptr);
        }
    }
    return NO;
}

+ (BOOL)removeStorage:(NSString *)mmapID mode:(KFKVMode)mode NS_SWIFT_NAME(removeStorage(for:mode:)) {
    auto rootPath = (mode & KFKVSingleProcess) ? nil : g_groupPath;
    return [self removeStorage:mmapID rootPath:rootPath];
}

+ (BOOL)checkExist:(NSString *)mmapID rootPath:(nullable NSString *)path NS_SWIFT_NAME(checkExist(for:rootPath:)) {
    if (mmapID.length > 0) {
        if (path.length > 0) {
            string rootPath(path.UTF8String);
            return kfkv::KFKV::checkExist(mmapID.UTF8String, &rootPath);
        } else {
            return kfkv::KFKV::checkExist(mmapID.UTF8String, nullptr);
        }
    }
    return NO;
}

+ (BOOL)checkExist:(NSString *)mmapID mode:(KFKVMode)mode NS_SWIFT_NAME(checkExist(for:mode:)) {
    auto rootPath = (mode & KFKVSingleProcess) ? nil : g_groupPath;
    return [self checkExist:mmapID rootPath:rootPath];
}

+ (KFKVNameSpace *)nameSpace:(NSString *)rootPath {
    kfkv::KFKV::nameSpace(rootPath.UTF8String);
    return [[KFKVNameSpace alloc] initWith:rootPath];
}

+ (KFKVNameSpace *)defaultNameSpace {
    if (!g_hasCalledInitializeKFKV) {
        KFKVWarning("KFKVEngine not initialized properly, must call +initializeKFKV: in main thread before calling any other KFKVEngine methods");
        return nil;
    }
    return [[KFKVNameSpace alloc] initWith:[self kfkvBasePath]];
}

@end

#pragma  mark - KFKVNameSpace

@implementation KFKVNameSpace {
    NSString *_rootPath;
    string *m_rootPath;
}

- (instancetype)initWith:(NSString *)path {
    if (self = [super init]) {
        _rootPath = path;
        m_rootPath = nullptr;
    }
    return self;
}

- (void) dealloc {
    _rootPath = nil;

    delete m_rootPath;
    m_rootPath = nullptr;
}

- (NSString *)rootPath {
    return _rootPath;
}

- (string *)strRootPath {
    if (!m_rootPath) {
        m_rootPath = new string(_rootPath.UTF8String);
    }
    return m_rootPath;
}

- (nullable KFKVEngine *)kfkvWithID:(nonnull NSString *)mmapID {
    return [KFKVEngine doGetWithID:mmapID cryptKey:nil aes256:NO rootPath:_rootPath mode:KFKVSingleProcess expectedCapacity:0];
}

- (nullable KFKVEngine *)kfkvWithID:(NSString *)mmapID config:(KFKVConfig)config NS_SWIFT_NAME(init(mmapID:config:)) {
    config.rootPath = _rootPath;
    return [KFKVEngine doGetWithID:mmapID config:config];
}

- (nullable KFKVEngine *)kfkvWithID:(nonnull NSString *)mmapID cryptKey:(nullable NSData *)cryptKey {
    return [KFKVEngine doGetWithID:mmapID cryptKey:cryptKey aes256:NO rootPath:_rootPath mode:KFKVSingleProcess expectedCapacity:0];
}

- (nullable KFKVEngine *)kfkvWithID:(nonnull NSString *)mmapID cryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 {
    return [KFKVEngine doGetWithID:mmapID cryptKey:cryptKey aes256:aes256 rootPath:_rootPath mode:KFKVSingleProcess expectedCapacity:0];
}

- (nullable KFKVEngine *)kfkvWithID:(nonnull NSString *)mmapID mode:(KFKVMode)mode {
    return [KFKVEngine doGetWithID:mmapID cryptKey:nil aes256:NO rootPath:_rootPath mode:mode expectedCapacity:0];
}

- (nullable KFKVEngine *)kfkvWithID:(nonnull NSString *)mmapID cryptKey:(nullable NSData *)cryptKey mode:(KFKVMode)mode {
    return [KFKVEngine doGetWithID:mmapID cryptKey:cryptKey aes256:NO rootPath:_rootPath mode:mode expectedCapacity:0];
}

- (nullable KFKVEngine *)kfkvWithID:(nonnull NSString *)mmapID cryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 mode:(KFKVMode)mode {
    return [KFKVEngine doGetWithID:mmapID cryptKey:cryptKey aes256:aes256 rootPath:_rootPath mode:mode expectedCapacity:0];
}

- (nullable KFKVEngine *)kfkvWithID:(nonnull NSString *)mmapID expectedCapacity:(size_t)expectedCapacity {
    return [KFKVEngine doGetWithID:mmapID cryptKey:nil aes256:NO rootPath:_rootPath mode:KFKVSingleProcess expectedCapacity:expectedCapacity];
}

- (nullable KFKVEngine *)kfkvWithID:(nonnull NSString *)mmapID cryptKey:(nullable NSData *)cryptKey expectedCapacity:(size_t)expectedCapacity {
    return [KFKVEngine doGetWithID:mmapID cryptKey:cryptKey aes256:NO rootPath:_rootPath mode:KFKVSingleProcess expectedCapacity:expectedCapacity];
}

- (nullable KFKVEngine *)kfkvWithID:(nonnull NSString *)mmapID cryptKey:(nullable NSData *)cryptKey aes256:(BOOL)aes256 expectedCapacity:(size_t)expectedCapacity {
    return [KFKVEngine doGetWithID:mmapID cryptKey:cryptKey aes256:aes256 rootPath:_rootPath mode:KFKVSingleProcess expectedCapacity:expectedCapacity];
}

- (BOOL)backupOneKFKV:(NSString *)mmapID toDirectory:(NSString *)dstDir {
    return kfkv::KFKV::backupOneToDirectory(mmapID.UTF8String, dstDir.UTF8String, [self strRootPath]);
}

- (BOOL)restoreOneKFKV:(NSString *)mmapID fromDirectory:(NSString *)srcDir {
    return kfkv::KFKV::restoreOneFromDirectory(mmapID.UTF8String, srcDir.UTF8String, [self strRootPath]);
}

- (size_t)backupAllToDirectory:(NSString *)dstDir {
    return kfkv::KFKV::backupAllToDirectory(dstDir.UTF8String, [self strRootPath]);
}

- (size_t)restoreAllFromDirectory:(NSString *)srcDir {
    return kfkv::KFKV::restoreAllFromDirectory(srcDir.UTF8String, [self strRootPath]);
}

- (BOOL)isFileValid:(NSString *)mmapID {
    return kfkv::KFKV::isFileValid(mmapID.UTF8String, [self strRootPath]);
}

- (BOOL)removeStorage:(NSString *)mmapID {
    return kfkv::KFKV::removeStorage(mmapID.UTF8String, [self strRootPath]);
}

- (BOOL)checkExist:(NSString *)mmapID {
    return kfkv::KFKV::checkExist(mmapID.UTF8String, [self strRootPath]);
}

@end
