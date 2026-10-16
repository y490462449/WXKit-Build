#pragma once
#import <Foundation/Foundation.h>

/// AI 自动回复（OpenAI 兼容 /chat/completions 接口）。
/// 关键点：API Key 是使用者自己的，请求直接从手机发往你自己配置的服务端，
/// 本项目不内置任何中转服务器，也不收集任何数据。
@interface WXKAI : NSObject

+ (void)start;
+ (void)handleWrap:(id)wrap;

/// 设置页"测试连接"用
+ (void)testConnection:(void (^)(BOOL ok, NSString *message))completion;
/// 最近一次状态（设置页展示）
+ (NSString *)lastStatus;

@end
