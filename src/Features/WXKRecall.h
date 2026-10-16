#pragma once
#import <Foundation/Foundation.h>

/// 防撤回：微信撤回时只发一条系统提示，原文不会重新下发。
/// 因此在消息到达时就缓存，撤回时按消息 id 反查原文，存进撤回记录并可选屏幕内提示。
@interface WXKRecall : NSObject

+ (void)start;
+ (void)handleWrap:(id)wrap;

@end
