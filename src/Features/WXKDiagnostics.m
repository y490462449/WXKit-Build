#import "WXKDiagnostics.h"
#import "WXKBridge.h"
#import "WXKHook.h"
#import "WXKLog.h"
#import "WXKPrefs.h"
#import "WXKCommon.h"
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

@implementation WXKDiagnostics

+ (NSArray<NSString *> *)classKeywords {
    return @[@"Msg", @"Message", @"Session", @"Chat", @"Contact", @"Friend", @"Group",
             @"Moment", @"Sns", @"RedEnvelop", @"Hongbao", @"Voice", @"Location", @"Login",
             @"Account", @"Revoke", @"Notify", @"ServiceCenter", @"MMService", @"Logic",
             @"Send", @"Sync", @"Tenpay", @"Pay"];
}

+ (NSArray<NSString *> *)interestingClassNames {
    NSArray<NSString *> *keywords = [self classKeywords];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        NSString *className = [NSString stringWithUTF8String:name];
        if ([className hasPrefix:@"_"] || [className hasPrefix:@"NS"] || [className hasPrefix:@"UI"]) {
            continue;   // 跳过系统类，微信内部类基本都在 APP 命名空间
        }
        for (NSString *keyword in keywords) {
            if ([className rangeOfString:keyword].location != NSNotFound) {
                [names addObject:className];
                break;
            }
        }
    }
    if (classes) free(classes);
    return [names.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSString *)buildClassDumpWithMethodKeywords:(NSArray<NSString *> *)methodKeywords
                                         limit:(NSUInteger)limit {
    NSArray<NSString *> *classNames = [self interestingClassNames];
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"# WXKit %@ 类名导出\n# 进程 %@ 微信 %@ 时间 %@\n# 命中类 %lu 个\n\n",
        WXK_VERSION,
        [[NSProcessInfo processInfo] processName],
        [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
        [NSDate date], (unsigned long)classNames.count];

    for (NSString *className in classNames) {
        if (out.length > limit) {
            [out appendString:@"\n# 已达到大小上限，截断\n"];
            break;
        }
        Class cls = objc_getClass(className.UTF8String);
        if (!cls) continue;
        [out appendFormat:@"\n=== %@ (super=%@) ===\n", className,
            class_getSuperclass(cls) ? NSStringFromClass(class_getSuperclass(cls)) : @"nil"];
        for (int isClassMethod = 1; isClassMethod >= 0; isClassMethod--) {
            Class target = isClassMethod ? object_getClass(cls) : cls;
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(target, &methodCount);
            for (unsigned int i = 0; i < methodCount; i++) {
                NSString *selector = NSStringFromSelector(method_getName(methods[i]));
                if (methodKeywords.count) {
                    BOOL hit = NO;
                    for (NSString *keyword in methodKeywords) {
                        if ([selector rangeOfString:keyword].location != NSNotFound) { hit = YES; break; }
                    }
                    if (!hit) continue;
                }
                const char *types = method_getTypeEncoding(methods[i]);
                [out appendFormat:@"  %@ %@  %s\n", isClassMethod ? @"+" : @"-", selector, types ?: "?"];
            }
            if (methods) free(methods);
        }
    }
    return out;
}

+ (NSString *)hookProbeReport {
    // 按"用途"分组扫，输出的每行都带方法签名（冒号个数 = 参数个数）
    NSArray<NSArray<NSString *> *> *groups = @[
        @[@"① 疑似收消息回调", @"MsgWrap"],
        @[@"② 疑似新消息相关", @"OnAddMsg"],
        @[@"③ 疑似收消息（其他命名）", @"AddMsg"],
        @[@"④ 疑似发消息", @"SendMsg"],
        @[@"⑤ 疑似发文本消息", @"SendText"],
        @[@"⑥ 服务总线取服务", @"getService:"],
        @[@"⑦ 疑似撤回相关", @"Revoke"],
    ];

    NSMutableArray<NSString *> *allClasses = [NSMutableArray array];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        NSString *className = [NSString stringWithUTF8String:name];
        if ([className hasPrefix:@"NS"] || [className hasPrefix:@"UI"] ||
            [className hasPrefix:@"_"] || [className hasPrefix:@"Web"] ||
            [className hasPrefix:@"WK"] || [className hasPrefix:@"CA"] ||
            [className hasPrefix:@"CG"] || [className hasPrefix:@"OS_"] ||
            [className hasPrefix:@"Swift"] || [className hasPrefix:@"__"]) {
            continue;
        }
        [allClasses addObject:className];
    }
    if (classes) free(classes);

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"# WXKit hook 目标探测\n# 微信 %@  系统 %@  时间 %@\n# 扫描类 %lu 个\n",
        [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
        [[UIDevice currentDevice] systemVersion],
        [NSDate date], (unsigned long)allClasses.count];

    NSUInteger totalLines = 0;
    for (NSArray<NSString *> *group in groups) {
        NSString *title = group.firstObject;
        NSString *keyword = group.lastObject;
        NSMutableArray<NSString *> *hits = [NSMutableArray array];
        for (NSString *className in allClasses) {
            Class cls = NSClassFromString(className);
            if (!cls) continue;
            for (int isClassMethod = 1; isClassMethod >= 0 && hits.count < 400; isClassMethod--) {
                Class target = isClassMethod ? object_getClass(cls) : cls;
                unsigned int methodCount = 0;
                Method *methods = class_copyMethodList(target, &methodCount);
                for (unsigned int i = 0; i < methodCount; i++) {
                    NSString *selector = NSStringFromSelector(method_getName(methods[i]));
                    if ([selector rangeOfString:keyword].location == NSNotFound) {
                        continue;
                    }
                    const char *types = method_getTypeEncoding(methods[i]);
                    [hits addObject:[NSString stringWithFormat:@"  %@ %@ %@   %s",
                                     className, isClassMethod ? @"+" : @"-", selector, types ?: "?"]];
                }
                if (methods) free(methods);
            }
        }
        if (!hits.count) {
            continue;
        }
        [out appendFormat:@"\n=== %@（%lu 条）===\n%@\n", title, (unsigned long)hits.count,
            [hits componentsJoinedByString:@"\n"]];
        totalLines += hits.count;
        if (totalLines > 1200) {
            [out appendString:@"\n（已达上限，先看前几组）\n"];
            break;
        }
    }
    if (!totalLines) {
        [out appendString:@"\n没有扫到任何候选项。可能是类名过滤太严，或这个版本改用了别的命名。\n"];
    }
    return out;
}

+ (NSString *)writeText:(NSString *)text fileName:(NSString *)fileName {
    if (!text.length || !fileName.length) return nil;
    NSString *path = [[WXKPrefs configDirectory] stringByAppendingPathComponent:fileName];
    NSError *error = nil;
    if (![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        WXKLog(@"[diag] 写入 %@ 失败: %@", path, error.localizedDescription);
        return nil;
    }
    WXKLog(@"[diag] 已写入 %@（%lu 字节）", path, (unsigned long)text.length);
    return path;
}

+ (NSArray<NSURL *> *)exportableFileURLs {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSString *dir = [WXKPrefs configDirectory];
    for (NSString *name in @[WXK_CLASS_DUMP_FILE, @"wxkit-hook-probe.txt", @"wxkit-selftest.txt",
                             @"wxkit-diagnostic.txt", WXK_LOG_FILE, @"recalls.plist"]) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [urls addObject:[NSURL fileURLWithPath:path]];
        }
    }
    return urls;
}

@end
