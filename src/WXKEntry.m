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
#import "WXKSettings.h"
#import "WXKDiagnostics.h"

static NSInteger gHookRetry = 0;

// 首次加载提示：只弹一次。它有两个作用——
//   1) 明确告诉使用者"dylib 确实加载并执行了"（这是注入环节唯一的正向信号）；
//   2) 万一悬浮球因为任何原因没显示，这里还能直接打开诊断报告，不至于无路可走。
static void WXKShowLoadedNoticeOnce(void) {
    WXKPrefs *prefs = [WXKPrefs shared];
    if ([prefs boolForKey:WXKKeyLoadedNotice]) {
        return;
    }
    [prefs setBool:YES forKey:WXKKeyLoadedNotice];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *key = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (!key) key = UIApplication.sharedApplication.windows.firstObject;
        UIViewController *top = key.rootViewController;
        while (top.presentedViewController) {
            top = top.presentedViewController;
        }
        if (!top) {
            WXKLog(@"[ui] 首次提示：找不到可弹窗的控制器");
            return;
        }
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"WXKit 已加载"
                             message:@"设置入口是屏幕边缘的「WX」悬浮球（可拖动，长按有菜单）。\n看不到悬浮球就点下面的诊断报告，把内容发回即可。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"诊断报告" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            NSArray<NSString *> *lines = WXKLogSnapshot();
            NSString *text = [NSString stringWithFormat:@"%@\n\n===== 最近日志 =====\n%@",
                              [WXKBridge diagnosticReport],
                              [lines componentsJoinedByString:@"\n"]];
            [WXKSettings presentTextPageWithTitle:@"WXKit 诊断" text:text];
        }]];
        [top presentViewController:alert animated:YES completion:nil];
    });
}

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
    WXKShowLoadedNoticeOnce();          // 首次加载提示：证明"确实加载了" + 兜底入口
}

__attribute__((constructor)) static void WXKEntry(void) {
    @autoreleasepool {
        // 构造函数跑得太早，UIKit 还没就绪，丢到主队列尾部
        dispatch_async(dispatch_get_main_queue(), ^{
            WXKStartModules();
        });
    }
}
