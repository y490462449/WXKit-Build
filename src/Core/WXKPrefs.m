#import "WXKPrefs.h"
#import "WXKCommon.h"
#import "WXKLog.h"
#import <pthread.h>

static pthread_mutex_t gPrefsLock = PTHREAD_MUTEX_INITIALIZER;

@interface WXKPrefs ()
@property (nonatomic, strong) NSMutableDictionary *store;
@end

@implementation WXKPrefs

+ (instancetype)shared {
    static WXKPrefs *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[WXKPrefs alloc] init];
        [shared reload];
    });
    return shared;
}

+ (NSDictionary *)defaults {
    return @{
        WXKKeyEnabled:            @YES,
        WXKKeyFloating:           @YES,
        WXKKeyFloatingX:          @(-1.0),      // -1 表示默认贴右边
        WXKKeyFloatingY:          @(160.0),
        WXKKeyLogContent:         @NO,
        WXKKeyVerboseLog:         @NO,

        WXKKeyRecallEnabled:      @YES,
        WXKKeyRecallToast:        @YES,
        WXKKeyRecallKeep:         @(200),

        WXKKeyAIEnabled:          @NO,
        WXKKeyAIBaseURL:          @"https://api.deepseek.com/v1",
        WXKKeyAIAPIKey:           @"",
        WXKKeyAIModel:            @"deepseek-chat",
        WXKKeyAISystemPrompt:     @"你是一个简洁、友好的中文聊天助手，回复控制在 60 字以内，不要暴露你是 AI 助手。",
        WXKKeyAIPrivateOnly:      @YES,
        WXKKeyAIGroupMentionOnly: @YES,
        WXKKeyAICooldown:         @(20),
        WXKKeyAIMaxLength:        @(200),
        WXKKeyAIContextMessages:  @(6),
        WXKKeyAITemperature:      @(0.8),
    };
}

+ (NSString *)configDirectory {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/WXKit"];
        [[NSFileManager defaultManager] createDirectoryAtPath:base
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        dir = base;
    });
    return dir;
}

+ (NSString *)configPath {
    return [[self configDirectory] stringByAppendingPathComponent:@"config.plist"];
}

- (instancetype)init {
    if ((self = [super init])) {
        _store = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)reload {
    NSMutableDictionary *merged = [[[self class] defaults] mutableCopy];
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:[[self class] configPath]];
    if (onDisk.count) {
        [merged addEntriesFromDictionary:onDisk];
    }
    pthread_mutex_lock(&gPrefsLock);
    self.store = merged;
    pthread_mutex_unlock(&gPrefsLock);
}

- (NSDictionary *)allValues {
    pthread_mutex_lock(&gPrefsLock);
    NSDictionary *copy = [self.store copy];
    pthread_mutex_unlock(&gPrefsLock);
    return copy;
}

- (void)resetAll {
    pthread_mutex_lock(&gPrefsLock);
    self.store = [[[self class] defaults] mutableCopy];
    pthread_mutex_unlock(&gPrefsLock);
    [self persistAndNotify];
}

- (id)objectForKey:(NSString *)key {
    if (!key.length) {
        return nil;
    }
    pthread_mutex_lock(&gPrefsLock);
    id value = self.store[key];
    pthread_mutex_unlock(&gPrefsLock);
    return value;
}

- (NSString *)stringForKey:(NSString *)key {
    id value = [self objectForKey:key];
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if (value) {
        return [value description];
    }
    return nil;
}

- (BOOL)boolForKey:(NSString *)key {
    return [[self objectForKey:key] respondsToSelector:@selector(boolValue)]
               ? [[self objectForKey:key] boolValue] : NO;
}

- (NSInteger)integerForKey:(NSString *)key {
    return [[self objectForKey:key] respondsToSelector:@selector(integerValue)]
               ? [[self objectForKey:key] integerValue] : 0;
}

- (double)doubleForKey:(NSString *)key {
    return [[self objectForKey:key] respondsToSelector:@selector(doubleValue)]
               ? [[self objectForKey:key] doubleValue] : 0.0;
}

- (void)setObject:(id)value forKey:(NSString *)key {
    if (!key.length) {
        return;
    }
    pthread_mutex_lock(&gPrefsLock);
    if (value) {
        self.store[key] = value;
    } else {
        [self.store removeObjectForKey:key];
    }
    pthread_mutex_unlock(&gPrefsLock);
    [self persistAndNotify];
}

- (void)setBool:(BOOL)value forKey:(NSString *)key       { [self setObject:@(value) forKey:key]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setDouble:(double)value forKey:(NSString *)key   { [self setObject:@(value) forKey:key]; }
- (void)removeKey:(NSString *)key                        { [self setObject:nil forKey:key]; }

- (void)persistAndNotify {
    NSDictionary *values = [self allValues];
    NSString *path = [[self class] configPath];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = [values writeToFile:path atomically:YES];
        if (!ok) {
            WXKLog(@"[prefs] 写入失败: %@", path);
        }
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:WXKPrefsChangedNotification object:nil];
    });
}

- (BOOL)boolEnabled        { return [self boolForKey:WXKKeyEnabled]; }
- (BOOL)boolVerbose        { return [self boolForKey:WXKKeyVerboseLog]; }
- (BOOL)boolLogContent     { return [self boolForKey:WXKKeyLogContent]; }
- (BOOL)boolFloating       { return [self boolForKey:WXKKeyFloating]; }
- (BOOL)boolRecallEnabled  { return [self boolForKey:WXKKeyRecallEnabled]; }
- (BOOL)boolRecallToast    { return [self boolForKey:WXKKeyRecallToast]; }
- (BOOL)boolAIEnabled      { return [self boolForKey:WXKKeyAIEnabled]; }

@end
