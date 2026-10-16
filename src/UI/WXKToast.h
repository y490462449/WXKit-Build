#pragma once
#import <Foundation/Foundation.h>

/// 屏幕内轻提示（不依赖系统通知权限，因为在微信进程里直接加一个小视图最稳）
@interface WXKToast : NSObject

+ (void)show:(NSString *)text;
+ (void)show:(NSString *)text duration:(NSTimeInterval)seconds;

@end
