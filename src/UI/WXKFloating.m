#import "WXKFloating.h"
#import "WXKSettings.h"
#import "WXKPrefs.h"
#import "WXKLog.h"
#import "WXKCommon.h"
#import "WXKBridge.h"
#import "WXKDiagnostics.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#define WXK_BALL_NORMAL 56.0
#define WXK_BALL_MINI   24.0

@interface WXKFloatingView : UIView
@property (nonatomic, strong) UIButton *button;
@end

@implementation WXKFloatingView
@end

@interface WXKFloating ()
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) WXKFloatingView *ball;
@property (nonatomic, assign) CGPoint panStart;
@property (nonatomic, assign) BOOL observersRegistered;
@property (nonatomic, assign) NSInteger retryCount;

+ (UIWindowScene *)activeWindowScene;
+ (UIWindow *)keyWindow;
- (void)createWindow;
- (void)layoutBall:(BOOL)normal;
- (CGRect)screenBounds;
- (void)ballTapped;
- (void)handlePan:(UIPanGestureRecognizer *)pan;
- (void)handleLongPress:(UILongPressGestureRecognizer *)press;
- (UIWindow *)hostWindow;
- (void)registerLifecycleObservers;
- (void)appDidBecomeActive;
@end

@implementation WXKFloating

+ (instancetype)shared {
    static WXKFloating *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[WXKFloating alloc] init];
    });
    return shared;
}

+ (void)install {
    dispatch_async(dispatch_get_main_queue(), ^{
        WXKFloating *f = [self shared];
        [f registerLifecycleObservers];
        if (f.window) {
            [f layoutBall:[WXKPrefs shared].boolFloating];
            return;
        }
        [f createWindow];
    });
}

// 启动早期可能还没有 keyWindow（尤其是被推送唤醒冷启动时），
// 这里既做退避重试，也在每次回到前台时自愈一次，避免"悬浮球有时不出现"。
- (void)registerLifecycleObservers {
    if (self.observersRegistered) {
        return;
    }
    self.observersRegistered = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)appDidBecomeActive {
    if (!self.window) {
        self.retryCount = 0;
        [self createWindow];
        return;
    }
    if (!self.window.windowScene) {
        // 之前创建时场景不可用 → 拆掉重建，否则会一直"看不见也不重试"
        WXKLog(@"[ui] 回到前台：窗口缺 windowScene，重建");
        self.window.hidden = YES;
        self.window = nil;
        self.ball = nil;
        [self createWindow];
        return;
    }
    self.window.hidden = NO;
    [self layoutBall:[WXKPrefs shared].boolFloating];
}

+ (void)setVisible:(BOOL)visible {
    dispatch_async(dispatch_get_main_queue(), ^{
        WXKFloating *f = [self shared];
        if (!f.window) {
            [self install];
            return;
        }
        [f layoutBall:visible];
    });
}

+ (void)resetPosition {
    [[WXKPrefs shared] setDouble:-1.0 forKey:WXKKeyFloatingX];
    [[WXKPrefs shared] setDouble:160.0 forKey:WXKKeyFloatingY];
    [self setVisible:YES];
    [[self shared] layoutBall:YES];
}

// 找一个可用的前台窗口场景。
// 关键：iOS 13+ 的场景化 App 里，**没有 windowScene 的 UIWindow 根本不会显示**，
// 所以拿不到场景时宁可重试，也不要创建一个永远看不见的窗口。
+ (UIWindowScene *)activeWindowScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        if (scene.activationState == UISceneActivationStateForegroundActive ||
            scene.activationState == UISceneActivationStateForegroundInactive) {
            return (UIWindowScene *)scene;
        }
    }
    UIWindow *key = [self keyWindow];
    return key.windowScene;
}

+ (UIWindow *)keyWindow {
    UIWindow *key = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if (w.isKeyWindow && !w.hidden) { key = w; break; }
    }
    return key ?: UIApplication.sharedApplication.windows.firstObject;
}

- (void)createWindow {
    CGFloat size = WXK_BALL_NORMAL;

    UIWindowScene *scene = [[self class] activeWindowScene];
    if (!scene) {
        if (self.retryCount++ < 20) {
            NSTimeInterval delay = MIN(0.5 * self.retryCount, 3.0);
            WXKLog(@"[ui] 还没有可用的 windowScene，%.1fs 后重试（第 %ld 次）", delay, (long)self.retryCount);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self createWindow];
            });
        } else {
            WXKLog(@"[ui] ⚠️ 一直拿不到 windowScene，悬浮球无法创建（回到前台会再试）");
        }
        return;
    }
    self.retryCount = 0;

    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    window.windowScene = scene;
    window.windowLevel = UIWindowLevelAlert + 1;
    window.backgroundColor = UIColor.clearColor;
    window.rootViewController = [[UIViewController alloc] init];
    window.rootViewController.view.backgroundColor = UIColor.clearColor;
    self.window = window;

    WXKFloatingView *ball = [[WXKFloatingView alloc] initWithFrame:window.bounds];
    ball.backgroundColor = UIColor.clearColor;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = ball.bounds;
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    button.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.55];
    button.layer.cornerRadius = size / 2.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    button.layer.masksToBounds = YES;
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    button.titleLabel.numberOfLines = 2;
    [button setTitle:@"WX" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button addTarget:self action:@selector(ballTapped) forControlEvents:UIControlEventTouchUpInside];
    [ball addSubview:button];
    ball.button = button;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [ball addGestureRecognizer:pan];
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    press.minimumPressDuration = 0.6;
    [ball addGestureRecognizer:press];

    window.rootViewController.view = ball;
    self.ball = ball;

    // 不调用 makeKeyAndVisible：避免抢走微信的键盘/菜单焦点
    window.hidden = NO;
    if (window.windowScene) {
        WXKLog(@"[ui] 悬浮球窗口已创建（scene 正常）");
    } else {
        // 理论上进不来（上面已确保有 scene），真进来了就拆掉重试，避免"看不见也不重试"
        WXKLog(@"[ui] ⚠️ 窗口没有 windowScene，拆掉重试");
        self.window = nil;
        [self createWindow];
        return;
    }
    [self layoutBall:[WXKPrefs shared].boolFloating];
}

// 屏幕尺寸：以 windowScene 的坐标空间为准（绝不用某个小窗口的 bounds 当屏幕）
- (CGRect)screenBounds {
    UIWindowScene *scene = self.window.windowScene ?: [[self class] activeWindowScene];
    CGRect bounds = CGRectZero;
    if (scene) {
        bounds = scene.coordinateSpace.bounds;
    }
    if (bounds.size.width < 100 || bounds.size.height < 200) {
        bounds = UIScreen.mainScreen.bounds;
    }
    return bounds;
}

- (void)layoutBall:(BOOL)normal {
    if (!self.window) return;
    CGFloat size = normal ? WXK_BALL_NORMAL : WXK_BALL_MINI;
    CGRect screen = [self screenBounds];
    CGFloat x = [[WXKPrefs shared] doubleForKey:WXKKeyFloatingX];
    CGFloat y = [[WXKPrefs shared] doubleForKey:WXKKeyFloatingY];
    if (x < 0) {
        x = screen.size.width - size - 8;
    }
    CGFloat maxX = MAX(0, screen.size.width - size - 4);
    CGFloat minY = 60;                                          // 避开状态栏
    CGFloat maxY = MAX(minY, screen.size.height - size - 40);
    x = MIN(MAX(0, x), maxX);
    if (y < minY || y > maxY) {
        y = MIN(MAX(minY, 160.0), maxY);                        // 越界就回默认位置，避免被摆到屏幕外
    }

    self.window.frame = CGRectMake(x, y, size, size);
    self.ball.frame = self.window.bounds;
    self.ball.button.frame = self.ball.bounds;
    self.ball.button.layer.cornerRadius = size / 2.0;
    self.ball.button.alpha = normal ? 1.0 : 0.7;
    self.ball.button.titleLabel.font = [UIFont systemFontOfSize:normal ? 15 : 10 weight:UIFontWeightSemibold];
    [self.ball.button setTitle:normal ? @"WX" : @"·" forState:UIControlStateNormal];
    WXKLog(@"[ui] 悬浮球位置 x=%.0f y=%.0f（屏幕 %.0fx%.0f）",
          x, y, screen.size.width, screen.size.height);
}

- (UIWindow *)hostWindow {
    return [[self class] keyWindow];
}

- (void)ballTapped {
    WXKLog(@"[ui] 打开设置");
    [WXKSettings present];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (!self.window) return;
    CGPoint translation = [pan translationInView:nil];
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.panStart = self.window.frame.origin;
    }
    CGFloat x = self.panStart.x + translation.x;
    CGFloat y = self.panStart.y + translation.y;
    CGRect screen = [self screenBounds];
    CGFloat size = self.window.frame.size.width;
    CGFloat maxX = MAX(0, screen.size.width - size - 4);
    CGFloat minY = 60;
    CGFloat maxY = MAX(minY, screen.size.height - size - 40);
    x = MIN(MAX(0, x), maxX);
    y = MIN(MAX(minY, y), maxY);
    self.window.frame = CGRectMake(x, y, size, size);

    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        // 松手后贴边
        CGFloat snapX = (x + size / 2 < screen.size.width / 2) ? 8 : screen.size.width - size - 8;
        [UIView animateWithDuration:0.18 animations:^{
            self.window.frame = CGRectMake(snapX, y, size, size);
        }];
        [[WXKPrefs shared] setDouble:snapX forKey:WXKKeyFloatingX];
        [[WXKPrefs shared] setDouble:y forKey:WXKKeyFloatingY];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan) return;
    UIViewController *top = self.hostWindow.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"WXKit"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"打开设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [WXKSettings present];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"一键导出诊断（类名+报告）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *report = [WXKBridge diagnosticReport];
            [WXKDiagnostics writeText:report fileName:@"wxkit-diagnostic.txt"];
            NSString *dump = [WXKDiagnostics buildClassDumpWithMethodKeywords:@[] limit:8 * 1024 * 1024];
            [WXKDiagnostics writeText:dump fileName:WXK_CLASS_DUMP_FILE];
            dispatch_async(dispatch_get_main_queue(), ^{
                [WXKSettings presentTextPageWithTitle:@"诊断报告" text:report];
            });
        });
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"缩到最小" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[WXKPrefs shared] setBool:NO forKey:WXKKeyFloating];
        [WXKFloating setVisible:NO];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"恢复默认位置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [WXKFloating resetPosition];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.ball;
        sheet.popoverPresentationController.sourceRect = self.ball.bounds;
    }
    [top presentViewController:sheet animated:YES completion:nil];
}

@end
