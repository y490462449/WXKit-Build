//
//  WXKEntry.m
//  插件入口。dylib 被 dyld 加载时构造函数就会跑（早于 WeChat 的 main），
//  所以这里只做"挂 hook + 注册"，真正的服务对象在收到消息时惰性获取。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "WXKCommon.h"
#import "WXKLog.h"
#import "WXKPrefs.h"
#import "WXKBridge.h"
#import "WXKMsgStore.h"
#import "WXKRecall.h"
#import "WXKAI.h"
#import "WXKFloating.h"
#import "WXKHook.h"

static NSInteger gHookRetry = 0;

static void WXKTryInstallHooks(void) {
    if ([WXKBridge installMessageHooks]) {
        return;
    }
    if (gHookRetry++ >= 12) {
        WXKLog(@"[init] 放弃自动挂新消息回调，请到设置里导出类名后反馈");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WXKTryInstallHooks();
    });
}

static void WXKStartModules(void) {
    WXKLog(@"[init] ===== WXKit %@ 启动 =====", WXK_VERSION);
    WXKLog(@"[init] 宿主 bundle=%@", [[NSBundle mainBundle] bundleIdentifier] ?: @"?");

    [WXKPrefs shared];                 // 建档配置（默认值 + 磁盘覆盖）
    [WXKMsgStore start];               // 先记住消息，防撤回才有原文可查
    [WXKRecall start];
    [WXKAI start];
    [WXKBridge start];

    WXKTryInstallHooks();
    [WXKFloating install];
}

__attribute__((constructor)) static void WXKEntry(void) {
    @autoreleasepool {
        // 构造函数跑得太早，UIKit 还没就绪，丢到主队列尾部
        dispatch_async(dispatch_get_main_queue(), ^{
            WXKStartModules();
        });
    }
}
