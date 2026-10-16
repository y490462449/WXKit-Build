#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// 设置面板（不用 PreferenceLoader，所以 TrollStore/TrollFools 注入时也能用）
@interface WXKSettings : NSObject

/// 弹出设置界面（内部会包一层导航控制器）
+ (void)present;
/// 弹出只读文本页（日志、诊断报告等）
+ (void)presentTextPageWithTitle:(NSString *)title text:(NSString *)text;

@end
