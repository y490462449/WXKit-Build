#pragma once
#import <Foundation/Foundation.h>

/// 真机自检：装好之后先点这个，把"到底哪一环没通"一次看清楚。
/// 只读检查 + 一次配置文件写入测试，不会发消息、不会联网。
@interface WXKSelfTest : NSObject

+ (NSString *)run;

@end
