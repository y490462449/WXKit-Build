#import "WXKMsgStore.h"
#import "WXKBridge.h"
#import "WXKLog.h"
#import "WXKPrefs.h"
#import "WXKCommon.h"
#import <pthread.h>

@implementation WXKMsgRecord
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@: %@>", self.session, self.sender, self.content];
}
@end

#define WXK_STORE_MAX 600

static NSMutableArray<WXKMsgRecord *> *gRecent = nil;
static NSMutableArray<NSDictionary *> *gRecalls = nil;
static pthread_mutex_t gStoreLock = PTHREAD_MUTEX_INITIALIZER;

static NSString *WXKRecallPath(void) {
    return [[WXKPrefs configDirectory] stringByAppendingPathComponent:@"recalls.plist"];
}

@interface WXKMsgStore ()
+ (void)handleWrap:(id)wrap;
@end

@implementation WXKMsgStore

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gRecent = [NSMutableArray array];
        NSArray *saved = [NSArray arrayWithContentsOfFile:WXKRecallPath()];
        gRecalls = saved ? [saved mutableCopy] : [NSMutableArray array];
        WXKLog(@"[store] 已加载，历史撤回记录 %lu 条", (unsigned long)gRecalls.count);
    });
    [WXKBridge addMessageHandler:^(id wrap) {
        [self handleWrap:wrap];
    }];
}

+ (void)handleWrap:(id)wrap {
    if ([WXKBridge isSystemWrap:wrap]) {
        return;   // 系统提示交给撤回模块处理
    }
    [self rememberWrap:wrap];
}

+ (void)rememberWrap:(id)wrap {
    WXKMsgRecord *r = [[WXKMsgRecord alloc] init];
    r.content  = [WXKBridge contentOfWrap:wrap] ?: @"";
    r.type     = [WXKBridge typeOfWrap:wrap];
    r.session  = [WXKBridge sessionOfWrap:wrap] ?: @"";
    r.sender   = [WXKBridge actualSenderOfWrap:wrap] ?: @"";
    r.serverId = [WXKBridge serverIdOfWrap:wrap];
    r.localId  = [WXKBridge messageIdOfWrap:wrap];
    r.time     = [WXKBridge timeOfWrap:wrap];
    if (r.time <= 0) {
        r.time = [[NSDate date] timeIntervalSince1970];
    }
    r.outgoing = [[WXKBridge selfUserName] isEqualToString:r.sender];
    if (!r.content.length) {
        return;
    }
    pthread_mutex_lock(&gStoreLock);
    [gRecent addObject:r];
    while (gRecent.count > WXK_STORE_MAX) {
        [gRecent removeObjectAtIndex:0];
    }
    pthread_mutex_unlock(&gStoreLock);
    WXKLogVerbose(@"[store] 记住 %@ <- %@ (%lu 字)", r.session, r.sender, (unsigned long)r.content.length);
}

+ (WXKMsgRecord *)recordForServerId:(long long)serverId session:(NSString *)session {
    if (serverId == 0) return nil;
    pthread_mutex_lock(&gStoreLock);
    WXKMsgRecord *found = nil;
    for (WXKMsgRecord *r in gRecent.reverseObjectEnumerator) {
        if (r.serverId == serverId) { found = r; break; }
    }
    pthread_mutex_unlock(&gStoreLock);
    return found;
}

+ (WXKMsgRecord *)recordForLocalId:(long long)localId session:(NSString *)session {
    if (localId == 0) return nil;
    pthread_mutex_lock(&gStoreLock);
    WXKMsgRecord *found = nil;
    for (WXKMsgRecord *r in gRecent.reverseObjectEnumerator) {
        if (r.localId == localId) { found = r; break; }
    }
    pthread_mutex_unlock(&gStoreLock);
    return found;
}

+ (NSArray<WXKMsgRecord *> *)recentMessagesForSession:(NSString *)session limit:(NSInteger)limit {
    NSMutableArray<WXKMsgRecord *> *out = [NSMutableArray array];
    pthread_mutex_lock(&gStoreLock);
    for (WXKMsgRecord *r in gRecent.reverseObjectEnumerator) {
        if (session.length && ![r.session isEqualToString:session]) {
            continue;
        }
        [out insertObject:r atIndex:0];
        if ((NSInteger)out.count >= limit) break;
    }
    pthread_mutex_unlock(&gStoreLock);
    return out;
}

+ (NSInteger)cachedCount {
    pthread_mutex_lock(&gStoreLock);
    NSInteger count = (NSInteger)gRecent.count;
    pthread_mutex_unlock(&gStoreLock);
    return count;
}

+ (void)addRecallRecord:(WXKMsgRecord *)original by:(NSString *)who session:(NSString *)session {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"time"] = @([[NSDate date] timeIntervalSince1970]);
    dict[@"session"] = session ?: original.session ?: @"";
    dict[@"sender"] = who ?: original.sender ?: @"";
    dict[@"content"] = original.content ?: @"";
    dict[@"originalTime"] = @(original.time);
    NSInteger keep = MAX(20, [[WXKPrefs shared] integerForKey:WXKKeyRecallKeep]);
    pthread_mutex_lock(&gStoreLock);
    [gRecalls insertObject:dict atIndex:0];
    while ((NSInteger)gRecalls.count > keep) {
        [gRecalls removeLastObject];
    }
    NSArray *snapshot = [gRecalls copy];
    pthread_mutex_unlock(&gStoreLock);
    [snapshot writeToFile:WXKRecallPath() atomically:YES];
    WXKLog(@"[recall] 记录撤回：%@ 在 %@ 撤回「%@」", dict[@"sender"], dict[@"session"], dict[@"content"]);
}

+ (NSArray<NSDictionary *> *)recallRecords {
    pthread_mutex_lock(&gStoreLock);
    NSArray *copy = [gRecalls copy];
    pthread_mutex_unlock(&gStoreLock);
    return copy;
}

+ (void)clearRecallRecords {
    pthread_mutex_lock(&gStoreLock);
    [gRecalls removeAllObjects];
    pthread_mutex_unlock(&gStoreLock);
    [[NSFileManager defaultManager] removeItemAtPath:WXKRecallPath() error:NULL];
}

@end
