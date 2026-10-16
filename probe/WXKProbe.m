//
//  WXKProbe.m —— 最小注入探针（v2：信号更可靠）
//
//  它只回答一个问题：dylib 到底有没有被加载进微信、并且真的跑起来？
//  不挂任何 hook、不改任何行为，所以"探针没反应"就一定等于注入/加载环节的问题，
//  与类名方法名对不对无关。
//
//  v2 修掉了一个会让结果误判的设计缺陷：
//  v1 把横幅加在宿主 App 的 keyWindow 上，而微信启动过程中会替换 rootViewController，
//  那一刻挂在它窗口上的子视图会被一起清掉 —— 看起来就像"注入了但什么都没发生"。
//  现在横幅由**自己的 UIWindow** 承载（宿主换什么都不会影响），并且额外弹一次原生弹窗，
//  两个信号出现任意一个，就说明 dylib 成功加载并执行了。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>

static UIWindow *gProbeWindow = nil;
static BOOL gAlertShown = NO;

static NSString *WXKProbeSummary(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    return [NSString stringWithFormat:
            @"dylib 已被加载并执行 ✅\n\n宿主: %@\n微信版本: %@\n构建号: %@\n进程: %@\n\n容器: %@",
            [bundle bundleIdentifier] ?: @"?",
            [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
            [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?",
            [[NSProcessInfo processInfo] processName],
            NSHomeDirectory()];
}

// 往容器里落个文件：证明能读能写，也说明不是"加载到一半就崩了"
static void WXKProbeWriteMarker(void) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/WXKit"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    NSString *path = [dir stringByAppendingPathComponent:@"probe.txt"];
    NSString *text = [NSString stringWithFormat:@"%@\n%@\n", [NSDate date], WXKProbeSummary()];
    BOOL ok = [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSLog(@"[WXKProbe] 写入标记文件 %@ ：%@", path, ok ? @"成功" : @"失败");
}

static UIWindow *WXKProbeKeyWindow(void) {
    UIWindow *key = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.isKeyWindow && !window.hidden) {
            key = window;
            break;
        }
    }
    return key ?: UIApplication.sharedApplication.windows.firstObject;
}

// 用自己的 UIWindow 承载横幅：宿主 App 替换 rootViewController 不会把它清掉
static void WXKProbeShowBanner(void) {
    if (gProbeWindow) {
        gProbeWindow.hidden = NO;
        return;
    }
    UIWindow *host = WXKProbeKeyWindow();
    if (!host) {
        return;
    }
    CGRect bounds = host.bounds;
    if (bounds.size.width < 1) {
        bounds = UIScreen.mainScreen.bounds;
    }

    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, bounds.size.width, 48)];
    if (@available(iOS 13.0, *)) {
        if (host.windowScene) {
            window.windowScene = host.windowScene;
        }
    }
    window.windowLevel = UIWindowLevelAlert + 2;
    window.backgroundColor = UIColor.clearColor;

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = UIColor.clearColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, bounds.size.width, 48)];
    label.text = @"WXKit 探针已注入 ✅";
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont boldSystemFontOfSize:15];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithRed:0.13 green:0.62 blue:0.28 alpha:0.95];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [root.view addSubview:label];
    window.rootViewController = root;
    window.hidden = NO;
    gProbeWindow = window;
    NSLog(@"[WXKProbe] 横幅已显示（窗口级别 %g）", window.windowLevel);
}

// 再给一个很难忽略的信号：弹一次原生弹窗
static void WXKProbeShowAlert(void) {
    if (gAlertShown) {
        return;
    }
    UIWindow *host = WXKProbeKeyWindow();
    UIViewController *top = host.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    if (!top) {
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"WXKit 探针：加载成功"
                                                                  message:WXKProbeSummary()
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    @try {
        [top presentViewController:alert animated:YES completion:nil];
        gAlertShown = YES;
        NSLog(@"[WXKProbe] 已弹出说明弹窗");
    } @catch (NSException *e) {
        NSLog(@"[WXKProbe] 弹窗失败：%@", e.reason);
    }
}

static void WXKProbeTick(NSInteger attempt) {
    WXKProbeShowBanner();
    if (attempt >= 2) {
        WXKProbeShowAlert();
    }
    if ((gProbeWindow != nil && gAlertShown) || attempt >= 25) {
        NSLog(@"[WXKProbe] 停止重试（横幅=%@，弹窗=%@）",
              gProbeWindow ? @"有" : @"无", gAlertShown ? @"有" : @"无");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WXKProbeTick(attempt + 1);
    });
}

__attribute__((constructor)) static void WXKProbeEntry(void) {
    @autoreleasepool {
        NSLog(@"[WXKProbe] ===== dylib 已被加载 =====");
        os_log_t log = os_log_create("com.wxkit.probe", "probe");
        os_log_info(log, "[WXKProbe] loaded into %{public}s",
                    [[NSProcessInfo processInfo] processName].UTF8String);

        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[WXKProbe] %@", WXKProbeSummary());
            WXKProbeWriteMarker();
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                WXKProbeShowBanner();
            }];
            WXKProbeTick(0);
        });
    }
}
