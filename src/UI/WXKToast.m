#import "WXKToast.h"
#import "WXKLog.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@interface WXKToast ()
+ (UIWindow *)hostWindow;
@end

@implementation WXKToast

+ (void)show:(NSString *)text {
    [self show:text duration:3.0];
}

+ (void)show:(NSString *)text duration:(NSTimeInterval)seconds {
    if (!text.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *host = [self hostWindow];
        if (!host) {
            WXKLog(@"[toast] 没有可用窗口，丢弃提示：%@", text);
            return;
        }
        UILabel *label = [[UILabel alloc] init];
        label.text = text;
        label.numberOfLines = 0;
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        label.textAlignment = NSTextAlignmentCenter;

        CGFloat maxWidth = host.bounds.size.width - 60;
        CGSize size = [label sizeThatFits:CGSizeMake(maxWidth - 24, CGFLOAT_MAX)];
        CGFloat width = MIN(maxWidth, size.width + 24);
        CGFloat height = size.height + 20;

        label.frame = CGRectMake(12, 10, width - 24, height - 20);
        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, height)];
        container.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.82];
        container.layer.cornerRadius = 12;
        container.layer.masksToBounds = YES;
        container.alpha = 0;
        [container addSubview:label];
        container.center = CGPointMake(host.bounds.size.width / 2, host.bounds.size.height * 0.72);
        container.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin |
                                     UIViewAutoresizingFlexibleRightMargin;
        [host addSubview:container];

        [UIView animateWithDuration:0.2 animations:^{
            container.alpha = 1.0;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.3 delay:seconds options:0 animations:^{
                container.alpha = 0.0;
            } completion:^(BOOL done) {
                [container removeFromSuperview];
            }];
        }];
    });
}

+ (UIWindow *)hostWindow {
    UIApplication *app = UIApplication.sharedApplication;
    for (UIWindow *w in app.windows.reverseObjectEnumerator) {
        if (w.isKeyWindow && !w.hidden) return w;
    }
    return app.windows.firstObject;
}

@end
