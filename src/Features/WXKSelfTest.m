#import "WXKSelfTest.h"
#import "WXKBridge.h"
#import "WXKHook.h"
#import "WXKLog.h"
#import "WXKPrefs.h"
#import "WXKMsgStore.h"
#import "WXKOverrides.h"
#import "WXKCommon.h"
#import <objc/runtime.h>
#import <stdarg.h>

@implementation WXKSelfTest

+ (void)line:(NSMutableString *)out ok:(BOOL)ok format:(NSString *)format, ... NS_FORMAT_FUNCTION(3, 4) {
    va_list ap;
    va_start(ap, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    [out appendFormat:@"%@ %@\n", ok ? @"✅" : @"❌", text];
}

+ (NSString *)run {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"WXKit 自检报告\n"];
    [out appendFormat:@"时间: %@\n", [NSDate date]];
    [out appendFormat:@"插件版本: %@\n", WXK_VERSION];
    [out appendFormat:@"宿主: %@ (%@)\n", [[NSProcessInfo processInfo] processName],
                       [[NSBundle mainBundle] bundleIdentifier] ?: @"?"];
    [out appendFormat:@"微信版本: %@\n", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?"];
    [out appendFormat:@"容器路径: %@\n\n", NSHomeDirectory()];

    NSInteger failures = 0;

    // 1. 配置读写
    [out appendString:@"【配置】\n"];
    NSString *probePath = [[WXKPrefs configDirectory] stringByAppendingPathComponent:@".selftest"];
    BOOL wrote = [@"ok" writeToFile:probePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    BOOL removable = [[NSFileManager defaultManager] removeItemAtPath:probePath error:NULL];
    [self line:out ok:wrote format:@"配置文件目录可写：%@", [WXKPrefs configDirectory]];
    if (!wrote || !removable) failures++;
    [self line:out ok:[[WXKPrefs shared] objectForKey:WXKKeyEnabled] != nil format:@"配置已加载"];

    // 2. 关键类是否存在
    [out appendString:@"\n【关键类】\n"];
    NSDictionary<NSString *, NSArray<NSString *> *> *probes = [WXKBridge diagnosticProbes];
    NSArray<NSString *> *classNames = [probes.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSInteger existing = 0;
    for (NSString *name in classNames) {
        BOOL exists = WXKClassExists(name);
        if (exists) existing++;
        [self line:out ok:exists format:@"%@", name];
    }
    [out appendFormat:@"（%ld/%lu 个候选类存在）\n", (long)existing, (unsigned long)classNames.count];
    if (existing == 0) failures++;

    // 3. 服务能不能取到
    [out appendString:@"\n【服务解析】\n"];
    id msgMgr = [WXKBridge messageManager];
    [self line:out ok:msgMgr != nil format:@"消息服务 = %@", msgMgr ? NSStringFromClass([msgMgr class]) : @"取不到"];
    if (!msgMgr) failures++;
    id contactMgr = [WXKBridge contactManager];
    [self line:out ok:contactMgr != nil format:@"通讯录服务 = %@", contactMgr ? NSStringFromClass([contactMgr class]) : @"取不到"];
    NSString *selfName = [WXKBridge selfUserName];
    [self line:out ok:selfName.length > 0 format:@"自己的 wxid = %@", selfName.length ? selfName : @"未解析出"];
    [self line:out ok:[WXKBridge selfDisplayName].length > 0 format:@"自己的昵称 = %@", [WXKBridge selfDisplayName]];

    // 4. hook 状态
    [out appendString:@"\n【hook 状态】\n"];
    NSArray<WXKHookRecord *> *records = [WXKHook records];
    NSInteger attached = 0;
    for (WXKHookRecord *record in records) {
        if (record.attached) attached++;
        [out appendFormat:@"%@ %@\n", record.attached ? @"✅" : @"❌", record];
    }
    if (!records.count) {
        [out appendString:@"（还没有任何 hook 记录）\n"];
    }
    [self line:out ok:[WXKBridge messageHooksInstalled] format:@"新消息回调已挂上"];
    if (![WXKBridge messageHooksInstalled]) failures++;

    // 5. 缓存与撤回
    [out appendString:@"\n【运行数据】\n"];
    [out appendFormat:@"消息缓存: %ld 条\n", (long)[WXKMsgStore cachedCount]];
    [out appendFormat:@"撤回记录: %lu 条\n", (unsigned long)[WXKMsgStore recallRecords].count];
    [out appendFormat:@"防撤回开关: %@\n", [WXKPrefs shared].boolRecallEnabled ? @"开" : @"关"];

    // 5.5 候选名覆盖状态（适配新版本用）
    [out appendString:@"\n【候选名覆盖】\n"];
    [out appendFormat:@"%@\n", [WXKOverrides summary]];

    // 6. AI 配置（只检查完整性，不联网）
    [out appendString:@"\n【AI 配置】\n"];
    WXKPrefs *prefs = [WXKPrefs shared];
    NSString *base = [prefs stringForKey:WXKKeyAIBaseURL];
    NSString *key = [prefs stringForKey:WXKKeyAIAPIKey];
    NSString *model = [prefs stringForKey:WXKKeyAIModel];
    [self line:out ok:base.length > 0 format:@"Base URL = %@", base.length ? base : @"(空)"];
    [self line:out ok:key.length > 0 format:@"API Key = %@", key.length ? @"已填写" : @"(空)"];
    [self line:out ok:model.length > 0 format:@"模型 = %@", model.length ? model : @"(空)"];
    [out appendFormat:@"AI 开关: %@\n", prefs.boolAIEnabled ? @"开" : @"关"];

    // 7. 结论
    [out appendString:@"\n【结论】\n"];
    if (failures == 0) {
        [out appendString:@"关键环节都通过了。接下来：随便收发一条消息，再看「查看日志」里有没有 [store]/[recall] 记录。\n"];
    } else {
        [out appendFormat:@"有 %ld 个关键环节没通过。请点「导出类名与方法」，把 wxkit-classes.txt 发给维护者，"
                          @"据此把候选类名/方法名换成你这一版微信的真实名字。\n", (long)failures];
    }
    WXKLog(@"[selftest] 完成，未通过项 %ld", (long)failures);
    return out;
}

@end
