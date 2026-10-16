#pragma once
#import <Foundation/Foundation.h>

/// 悬浮球：设置界面的入口。
/// 为了兼容"不能改微信界面结构"的情况，用独立的小 UIWindow 承载，不依赖 PreferenceLoader，
/// 也不会抢走微信的 keyWindow（只在自己 56pt 范围内接收触摸）。
@interface WXKFloating : NSObject

+ (void)install;
/// YES = 正常悬浮球；NO = 缩成半透明小点（仍可点开设置，避免把自己锁在外面）
+ (void)setVisible:(BOOL)visible;
+ (void)resetPosition;

@end
