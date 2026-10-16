//
//  WXKProbe.m —— 最小注入探针
//
//  它只回答一个问题：这个 dylib 到底有没有被成功加载进微信进程？
//  不挂任何 hook、不改任何行为，所以"探针没反应"就一定等于注入/签名环节的问题，
//  与类名方法名对不对无关。装好后先注它，链路确认了再注完整版 WXKit。
//
//  成功标志：微信里出现一条绿色的「WXKit 探针已注入」横幅，点它能看详细信息。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>

static UILabel *gBanner = nil;

static NSString *WXKProbeSummary(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    return [NSString stringWithFormat:
            @"探针已注入 ✅\n\n宿主: %@\n微信版本: %@\n构建号: %@\n进程: %@\n\n容器: %@",
            [bundle bundleIdentifier] ?: @"?",
            [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
            [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?",
            [[NSProcessInfo processInfo] processName],
            NSHomeDirectory()];
}

// 往容器里落一个文件：顺带证明"能读能写"，也说明不是加载到一半就崩了
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

@interface WXKProbeDetail : NSObject
+ (void)present;
@end

@implementation WXKProbeDetail

+ (void)present {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"WXKit 探针"
                                                                  message:WXKProbeSummary()
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *top = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.isKeyWindow) {
            top = window.rootViewController;
            break;
        }
    }
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    if (top) {
        [top presentViewController:alert animated:YES completion:nil];
    }
}

@end

@interface WXKProbeBannerTarget : NSObject
- (void)showDetail;
@end

@implementation WXKProbeBannerTarget
- (void)showDetail {
    [WXKProbeDetail present];
}
@end

static WXKProbeBannerTarget *gTarget = nil;

static UIWindow *WXKProbeHostWindow(void) {
    UIWindow *host = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (window.isKeyWindow && !window.hidden) {
            host = window;
            break;
        }
    }
    if (!host) {
        host = UIApplication.sharedApplication.windows.firstObject;
    }
    return host;
}

static void WXKProbeShowBanner(void) {
    if (gBanner.superview) {
        return;
    }
    UIWindow *host = WXKProbeHostWindow();
    if (!host) {
        return;   // 还没有窗口，交给重试逻辑
    }

    CGFloat width = host.bounds.size.width - 24;
    UILabel *banner = [[UILabel alloc] initWithFrame:CGRectMake(12, host.safeAreaInsets.top + 8, width, 30)];
    banner.text = @"WXKit 探针已注入 · 点我";
    banner.textAlignment = NSTextAlignmentCenter;
    banner.font = [UIFont boldSystemFontOfSize:13];
    banner.textColor = UIColor.whiteColor;
    banner.backgroundColor = [UIColor colorWithRed:0.13 green:0.62 blue:0.28 alpha:0.92];
    banner.layer.cornerRadius = 8;
    banner.layer.masksToBounds = YES;
    banner.userInteractionEnabled = YES;
    banner.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    if (!gTarget) {
        gTarget = [[WXKProbeBannerTarget alloc] init];
    }
    [banner addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:gTarget
                                                                        action:@selector(showDetail)]];
    [host addSubview:banner];
    gBanner = banner;
    NSLog(@"[WXKProbe] 横幅已显示");
}

static void WXKProbeInstallBannerWithRetry(NSInteger attempt) {
    if (gBanner.superview) {
        return;
    }
    WXKProbeShowBanner();
    if (gBanner.superview) {
        return;
    }
    if (attempt >= 12) {
        NSLog(@"[WXKProbe] 多次重试仍没有窗口（可能被推送唤醒冷启动）");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WXKProbeInstallBannerWithRetry(attempt + 1);
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
            WXKProbeInstallBannerWithRetry(0);
        });
    }
}
